import Foundation

struct ReceiptEventParser {
    private let coercion = LauncherParsingCoercion()

    mutating func parse(line: String) -> ParsedReceiptUpdate {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let payload = coercion.parseJSONObject(from: trimmed) else {
            return ParsedReceiptUpdate()
        }

        var update = ParsedReceiptUpdate()
        if let phaseRaw = payload["phase"] as? String {
            update.phase = LauncherPhase.fromReceiptPhase(phaseRaw)
        }

        guard let eventType = payload["event_type"] as? String else {
            return update
        }

        let eventIndex = coercion.intValue(from: payload["event_index"]) ?? 0
        let data = payload["data"] as? [String: Any] ?? [:]

        switch eventType {
        case "SCAN_PROGRESS":
            update.scannedFilesCheckedCount = coercion.intValue(from: data["files_checked"])
            update.scannedCheckedBytes = coercion.int64Value(from: data["bytes_checked"])
            update.scannedCandidateCount = coercion.intValue(from: data["candidate_count"])
            if let photos = data["photos"] as? [String: Any] {
                update.scanPhotoCount = coercion.intValue(from: photos["count"])
                update.scanPhotoBytes = coercion.int64Value(from: photos["bytes"])
            }
            if let videos = data["videos"] as? [String: Any] {
                update.scanVideoCount = coercion.intValue(from: videos["count"])
                update.scanVideoBytes = coercion.int64Value(from: videos["bytes"])
            }
            update.currentFilePath = coercion.currentPath(from: data)
        case "SCAN_SUMMARY":
            update.scannedCandidateCount = coercion.intValue(from: data["candidate_count"])
            if let photos = data["photos"] as? [String: Any] {
                update.scanPhotoCount = coercion.intValue(from: photos["count"])
                update.scanPhotoBytes = coercion.int64Value(from: photos["bytes"])
            }
            if let videos = data["videos"] as? [String: Any] {
                update.scanVideoCount = coercion.intValue(from: videos["count"])
                update.scanVideoBytes = coercion.int64Value(from: videos["bytes"])
            }
        case "PLAN_COMPUTED":
            if let files = data["files"] as? [[String: Any]] {
                update.plannedStageAndCommit = files.reduce(0) { partial, file in
                    partial + ((file["outcome"] as? String) == "stage_and_commit" ? 1 : 0)
                }
                update.duplicateNotCopied = files.reduce(0) { partial, file in
                    partial + ((file["outcome"] as? String) == "duplicate_not_copied" ? 1 : 0)
                }
            } else {
                update.plannedStageAndCommit = coercion.intValue(from: data["planned_file_count"])
                update.duplicateNotCopied = coercion.intValue(from: data["duplicate_not_copied_count"])
            }
        case "FILE_COPY_STARTED":
            guard coercion.boolValue(from: data["executed"]) != false else {
                return update
            }
            let status = (data["status"] as? String)?.lowercased()
            if status != "queued" && status != "planned" {
                update.copiedIncrement = 1
                update.currentFilePath = coercion.currentPath(from: data)
            }
        case "FILE_VERIFY_STARTED":
            guard coercion.boolValue(from: data["executed"]) != false else {
                return update
            }
            update.currentFilePath = coercion.currentPath(from: data)
        case "FILE_VERIFIED":
            guard coercion.boolValue(from: data["executed"]) != false else {
                return update
            }
            if data["outcome"] as? String == "verified" {
                update.verifiedIncrement = 1
            }
        case "FILE_COMMIT_STARTED":
            guard coercion.boolValue(from: data["executed"]) != false else {
                return update
            }
            update.currentFilePath = coercion.currentPath(from: data)
        case "FILE_COMMITTED":
            guard coercion.boolValue(from: data["executed"]) != false else {
                return update
            }
            if data["status"] as? String == "committed" {
                update.committedIncrement = 1
            }
        case "ERROR":
            let message = (data["error"] as? String) ?? "Unknown error"
            update.errorItem = ReceiptErrorItem(
                eventIndex: eventIndex,
                phase: update.phase,
                message: message,
                paths: extractErrorPaths(from: data)
            )
        case "SUMMARY":
            if let outcomes = data["totals_by_outcome"] as? [String: Any] {
                update.finalizedCommittedCount = coercion.intValue(from: outcomes["committed"])
                update.finalizedDuplicateNotCopiedCount = coercion.intValue(from: outcomes["duplicate_not_copied"])

                if let committed = update.finalizedCommittedCount,
                   let duplicates = update.finalizedDuplicateNotCopiedCount {
                    let dryRun = coercion.boolValue(from: data["dry_run"]) ?? false
                    let status = (data["status"] as? String)?.lowercased() ?? ""
                    update.finalizedIdempotentRerun = !dryRun && status == "completed" && committed == 0 && duplicates > 0
                }
            }
            let phaseTimings = parsePhaseTimings(data["phase_timings_ms"])
            if !phaseTimings.isEmpty {
                update.finalizedPhaseTimings = phaseTimings
                update.finalizedTotalDurationMs = phaseTimings.reduce(0) { partial, timing in
                    partial + timing.milliseconds
                }
            }
            if let touched = data["touched_paths"] as? [String: Any] {
                update.touchedPaths = flattenTouchedPaths(touched)
                update.createdDirectories = coercion.extractStringArray(touched["created_directories"])
            }
            if let pdfSummaryPath = data["pdf_summary_path"] as? String,
               !pdfSummaryPath.isEmpty,
               pdfSummaryPath != "not_written" {
                update.pdfSummaryPath = pdfSummaryPath
            }
        default:
            break
        }

        return update
    }

    private func extractErrorPaths(from data: [String: Any]) -> [String] {
        var paths: [String] = []
        let directPathKeys = [
            "path",
            "source_path",
            "staging_path",
            "final_path",
            "planned_final_path",
            "attempted_final_path",
        ]

        for key in directPathKeys {
            if let path = data[key] as? String, !path.isEmpty {
                paths.append(path)
            }
        }

        if let moved = data["moved_before_failure"] as? [[String: Any]] {
            for entry in moved {
                if let stagingPath = entry["staging_path"] as? String, !stagingPath.isEmpty {
                    paths.append(stagingPath)
                }
                if let finalPath = entry["final_path"] as? String, !finalPath.isEmpty {
                    paths.append(finalPath)
                }
            }
        }

        if let remaining = data["remaining_after_failure"] as? [[String: Any]] {
            for entry in remaining {
                if let stagingPath = entry["staging_path"] as? String, !stagingPath.isEmpty {
                    paths.append(stagingPath)
                }
                if let finalPath = entry["planned_final_path"] as? String, !finalPath.isEmpty {
                    paths.append(finalPath)
                }
            }
        }

        return coercion.deduped(paths)
    }

    private func flattenTouchedPaths(_ touched: [String: Any]) -> [String] {
        var paths: [String] = []

        for value in touched.values {
            if let directPaths = value as? [String] {
                paths.append(contentsOf: directPaths.filter { !$0.isEmpty })
                continue
            }

            if let moveEntries = value as? [[String: Any]] {
                for entry in moveEntries {
                    if let from = entry["from"] as? String, !from.isEmpty {
                        paths.append(from)
                    }
                    if let to = entry["to"] as? String, !to.isEmpty {
                        paths.append(to)
                    }
                    if let stagingPath = entry["staging_path"] as? String, !stagingPath.isEmpty {
                        paths.append(stagingPath)
                    }
                    if let finalPath = entry["final_path"] as? String, !finalPath.isEmpty {
                        paths.append(finalPath)
                    }
                    if let plannedFinalPath = entry["planned_final_path"] as? String, !plannedFinalPath.isEmpty {
                        paths.append(plannedFinalPath)
                    }
                }
            }
        }

        return coercion.deduped(paths)
    }

    private func parsePhaseTimings(_ value: Any?) -> [ParsedReceiptUpdate.PhaseTiming] {
        guard let entries = value as? [[String: Any]] else {
            return []
        }

        var timings: [ParsedReceiptUpdate.PhaseTiming] = []
        for entry in entries {
            guard let phaseRaw = entry["phase"] as? String,
                  let phase = LauncherPhase.fromReceiptPhase(phaseRaw),
                  let milliseconds = coercion.intValue(from: entry["milliseconds"]) else {
                continue
            }

            timings.append(.init(phase: phase, milliseconds: max(milliseconds, 0)))
        }

        return timings
    }
}
