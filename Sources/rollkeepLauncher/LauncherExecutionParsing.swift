import Foundation

enum LauncherPhase: String, Equatable {
    case idle
    case scan
    case plan
    case copy
    case verify
    case commit
    case finalize
    case finished

    var displayName: String {
        switch self {
        case .idle:
            return "Idle"
        case .scan:
            return "Scan"
        case .plan:
            return "Plan"
        case .copy:
            return "Copy"
        case .verify:
            return "Verify"
        case .commit:
            return "Commit"
        case .finalize:
            return "Finalize"
        case .finished:
            return "Finished"
        }
    }

    static func fromReceiptPhase(_ value: String) -> LauncherPhase? {
        switch value {
        case "scan":
            return .scan
        case "plan":
            return .plan
        case "copy":
            return .copy
        case "verify":
            return .verify
        case "commit":
            return .commit
        case "finalize":
            return .finalize
        default:
            return nil
        }
    }
}

enum LauncherRunResult: Equatable {
    case success
    case failure
}

struct ParsedOutputUpdate: Equatable {
    var phase: LauncherPhase?
    var receiptPath: String?
    var pdfSummaryPath: String?
    var stagingPath: String?
    var scannedCandidateCount: Int?
    var scanPhotoCount: Int?
    var scanVideoCount: Int?
    var scanPhotoBytes: Int64?
    var scanVideoBytes: Int64?
    var result: LauncherRunResult?
    var failureReason: String?
    var idempotentRerun: Bool?
}

struct CLIOutputParser {
    mutating func parse(line: String) -> ParsedOutputUpdate {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return ParsedOutputUpdate()
        }

        var update = ParsedOutputUpdate()

        if let payload = parseJSONObject(from: trimmed) {
            if let receiptPath = payload["receipt_path"] as? String {
                update.receiptPath = receiptPath
            }

            if let stagingPath = payload["staging_session_path"] as? String {
                update.stagingPath = stagingPath
            }

            if let message = payload["message"] as? String,
               let mappedPhase = phase(forLogMessage: message) {
                update.phase = mappedPhase
            }

            if let message = payload["message"] as? String, message == "scan_summary" {
                update.scannedCandidateCount = intValue(from: payload["candidate_count"])

                if let photos = payload["photos"] as? [String: Any] {
                    update.scanPhotoCount = intValue(from: photos["count"])
                    update.scanPhotoBytes = int64Value(from: photos["bytes"])
                } else {
                    update.scanPhotoCount = intValue(from: payload["photo_count"])
                    update.scanPhotoBytes = int64Value(from: payload["photo_bytes"])
                }

                if let videos = payload["videos"] as? [String: Any] {
                    update.scanVideoCount = intValue(from: videos["count"])
                    update.scanVideoBytes = int64Value(from: videos["bytes"])
                } else {
                    update.scanVideoCount = intValue(from: payload["video_count"])
                    update.scanVideoBytes = int64Value(from: payload["video_bytes"])
                }
            }
        }

        if trimmed == "Rollkeep Final Summary" {
            update.phase = .finalize
        }

        if trimmed.hasPrefix("Status: ") {
            let label = String(trimmed.dropFirst("Status: ".count)).uppercased()
            if label.contains("FAILED") {
                update.phase = .finished
                update.result = .failure
            } else if label.contains("VERIFIED") || label.contains("COMPLETED") || label.contains("DRY RUN") {
                update.phase = .finished
                update.result = .success
            }
        }

        if trimmed.hasPrefix("Receipt: ") {
            let rawValue = String(trimmed.dropFirst("Receipt: ".count))
            if let markerRange = rawValue.range(of: " [", options: .backwards) {
                update.receiptPath = String(rawValue[..<markerRange.lowerBound])
            } else {
                update.receiptPath = rawValue
            }
        }

        if trimmed.hasPrefix("PDF summary: ") {
            update.pdfSummaryPath = String(trimmed.dropFirst("PDF summary: ".count))
        }

        if trimmed.hasPrefix("- phase: ") {
            let phaseName = String(trimmed.dropFirst("- phase: ".count))
            if let mappedPhase = LauncherPhase.fromReceiptPhase(phaseName) {
                update.phase = mappedPhase
            }
        }

        if trimmed.hasPrefix("- reason: ") {
            update.failureReason = String(trimmed.dropFirst("- reason: ".count))
        }

        if trimmed.hasPrefix("- staging: ") {
            update.stagingPath = String(trimmed.dropFirst("- staging: ".count))
        }

        if trimmed.hasPrefix("Idempotency: ") {
            let label = String(trimmed.dropFirst("Idempotency: ".count))
            let classification = label
                .split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
                .first
                .map(String.init)?
                .lowercased()
            if let classification {
                update.idempotentRerun = classification == "idempotent_rerun"
            }
        }

        return update
    }

    private func parseJSONObject(from value: String) -> [String: Any]? {
        guard let data = value.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let payload = object as? [String: Any] else {
            return nil
        }
        return payload
    }

    private func intValue(from value: Any?) -> Int? {
        if let integer = value as? Int {
            return integer
        }
        if let number = value as? NSNumber {
            return number.intValue
        }
        if let text = value as? String {
            return Int(text)
        }
        return nil
    }

    private func int64Value(from value: Any?) -> Int64? {
        if let integer = value as? Int64 {
            return integer
        }
        if let integer = value as? Int {
            return Int64(integer)
        }
        if let number = value as? NSNumber {
            return number.int64Value
        }
        if let text = value as? String {
            return Int64(text)
        }
        return nil
    }

    private func phase(forLogMessage message: String) -> LauncherPhase? {
        switch message {
        case "command_started":
            return .scan
        case "scan_summary":
            return .plan
        case "plan_summary":
            return .copy
        case "copy_stage_completed":
            return .verify
        case "commit_stage_completed":
            return .commit
        case "dry_run_complete", "staging_session_removed", "receipt_pdf_written", "receipt_pdf_write_failed":
            return .finalize
        default:
            break
        }

        if message.contains("scan") {
            return .scan
        }
        if message.contains("plan") {
            return .plan
        }
        if message.contains("copy") {
            return .copy
        }
        if message.contains("verify") {
            return .verify
        }
        if message.contains("commit") {
            return .commit
        }
        if message.contains("finalize") || message.contains("receipt") {
            return .finalize
        }

        return nil
    }
}

struct ReceiptErrorItem: Equatable {
    let eventIndex: Int
    let phase: LauncherPhase?
    let message: String
    let paths: [String]
}

struct ParsedReceiptUpdate: Equatable {
    struct PhaseTiming: Equatable {
        let phase: LauncherPhase
        let milliseconds: Int
    }

    var phase: LauncherPhase?
    var scannedCandidateCount: Int?
    var scannedFilesCheckedCount: Int?
    var scannedCheckedBytes: Int64?
    var scanPhotoCount: Int? = nil
    var scanVideoCount: Int? = nil
    var scanPhotoBytes: Int64? = nil
    var scanVideoBytes: Int64? = nil
    var plannedStageAndCommit: Int?
    var duplicateNotCopied: Int?
    var copiedIncrement = 0
    var verifiedIncrement = 0
    var committedIncrement = 0
    var currentFilePath: String?
    var finalizedCommittedCount: Int?
    var finalizedDuplicateNotCopiedCount: Int?
    var finalizedIdempotentRerun: Bool?
    var finalizedPhaseTimings: [PhaseTiming]?
    var finalizedTotalDurationMs: Int?
    var pdfSummaryPath: String?
    var errorItem: ReceiptErrorItem?
    var touchedPaths: [String]?
    var createdDirectories: [String]?
}

struct ReceiptEventParser {
    mutating func parse(line: String) -> ParsedReceiptUpdate {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let payload = parseJSONObject(from: trimmed) else {
            return ParsedReceiptUpdate()
        }

        var update = ParsedReceiptUpdate()
        if let phaseRaw = payload["phase"] as? String {
            update.phase = LauncherPhase.fromReceiptPhase(phaseRaw)
        }

        guard let eventType = payload["event_type"] as? String else {
            return update
        }

        let eventIndex = intValue(from: payload["event_index"]) ?? 0
        let data = payload["data"] as? [String: Any] ?? [:]

        switch eventType {
        case "SCAN_PROGRESS":
            update.scannedFilesCheckedCount = intValue(from: data["files_checked"])
            update.scannedCheckedBytes = int64Value(from: data["bytes_checked"])
            update.scannedCandidateCount = intValue(from: data["candidate_count"])
            if let photos = data["photos"] as? [String: Any] {
                update.scanPhotoCount = intValue(from: photos["count"])
                update.scanPhotoBytes = int64Value(from: photos["bytes"])
            }
            if let videos = data["videos"] as? [String: Any] {
                update.scanVideoCount = intValue(from: videos["count"])
                update.scanVideoBytes = int64Value(from: videos["bytes"])
            }
            update.currentFilePath = currentPath(from: data)
        case "SCAN_SUMMARY":
            update.scannedCandidateCount = intValue(from: data["candidate_count"])
            if let photos = data["photos"] as? [String: Any] {
                update.scanPhotoCount = intValue(from: photos["count"])
                update.scanPhotoBytes = int64Value(from: photos["bytes"])
            }
            if let videos = data["videos"] as? [String: Any] {
                update.scanVideoCount = intValue(from: videos["count"])
                update.scanVideoBytes = int64Value(from: videos["bytes"])
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
                update.plannedStageAndCommit = intValue(from: data["planned_file_count"])
                update.duplicateNotCopied = intValue(from: data["duplicate_not_copied_count"])
            }
        case "FILE_COPY_STARTED":
            guard boolValue(from: data["executed"]) != false else {
                return update
            }
            let status = (data["status"] as? String)?.lowercased()
            if status != "queued" && status != "planned" {
                update.copiedIncrement = 1
                update.currentFilePath = currentPath(from: data)
            }
        case "FILE_VERIFY_STARTED":
            guard boolValue(from: data["executed"]) != false else {
                return update
            }
            update.currentFilePath = currentPath(from: data)
        case "FILE_VERIFIED":
            guard boolValue(from: data["executed"]) != false else {
                return update
            }
            if data["outcome"] as? String == "verified" {
                update.verifiedIncrement = 1
            }
        case "FILE_COMMIT_STARTED":
            guard boolValue(from: data["executed"]) != false else {
                return update
            }
            update.currentFilePath = currentPath(from: data)
        case "FILE_COMMITTED":
            guard boolValue(from: data["executed"]) != false else {
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
                update.finalizedCommittedCount = intValue(from: outcomes["committed"])
                update.finalizedDuplicateNotCopiedCount = intValue(from: outcomes["duplicate_not_copied"])

                if let committed = update.finalizedCommittedCount,
                   let duplicates = update.finalizedDuplicateNotCopiedCount {
                    let dryRun = boolValue(from: data["dry_run"]) ?? false
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
                update.createdDirectories = extractStringArray(touched["created_directories"])
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

    private func parseJSONObject(from value: String) -> [String: Any]? {
        guard let data = value.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let payload = object as? [String: Any] else {
            return nil
        }
        return payload
    }

    private func intValue(from value: Any?) -> Int? {
        if let integer = value as? Int {
            return integer
        }
        if let number = value as? NSNumber {
            return number.intValue
        }
        if let text = value as? String {
            return Int(text)
        }
        return nil
    }

    private func int64Value(from value: Any?) -> Int64? {
        if let integer = value as? Int64 {
            return integer
        }
        if let integer = value as? Int {
            return Int64(integer)
        }
        if let number = value as? NSNumber {
            return number.int64Value
        }
        if let text = value as? String {
            return Int64(text)
        }
        return nil
    }

    private func boolValue(from value: Any?) -> Bool? {
        if let bool = value as? Bool {
            return bool
        }
        if let number = value as? NSNumber {
            return number.boolValue
        }
        if let text = value as? String {
            switch text.lowercased() {
            case "true":
                return true
            case "false":
                return false
            default:
                return nil
            }
        }
        return nil
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

        return deduped(paths)
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

        return deduped(paths)
    }

    private func deduped(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for value in values where !value.isEmpty {
            if seen.insert(value).inserted {
                ordered.append(value)
            }
        }
        return ordered
    }

    private func extractStringArray(_ value: Any?) -> [String]? {
        guard let values = value as? [String] else {
            return nil
        }
        return deduped(values.filter { !$0.isEmpty })
    }

    private func parsePhaseTimings(_ value: Any?) -> [ParsedReceiptUpdate.PhaseTiming] {
        guard let entries = value as? [[String: Any]] else {
            return []
        }

        var timings: [ParsedReceiptUpdate.PhaseTiming] = []
        for entry in entries {
            guard let phaseRaw = entry["phase"] as? String,
                  let phase = LauncherPhase.fromReceiptPhase(phaseRaw),
                  let milliseconds = intValue(from: entry["milliseconds"]) else {
                continue
            }

            timings.append(.init(phase: phase, milliseconds: max(milliseconds, 0)))
        }

        return timings
    }

    private func currentPath(from data: [String: Any]) -> String? {
        let keys = ["path", "source_path", "staging_path", "final_path"]
        for key in keys {
            if let path = data[key] as? String, !path.isEmpty {
                return path
            }
        }
        return nil
    }
}

