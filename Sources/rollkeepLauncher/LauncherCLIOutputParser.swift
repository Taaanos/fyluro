import Foundation

struct CLIOutputParser {
    private let coercion = LauncherParsingCoercion()

    mutating func parse(line: String) -> ParsedOutputUpdate {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return ParsedOutputUpdate()
        }

        var update = ParsedOutputUpdate()

        if let payload = coercion.parseJSONObject(from: trimmed) {
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
                update.scannedCandidateCount = coercion.intValue(from: payload["candidate_count"])

                if let photos = payload["photos"] as? [String: Any] {
                    update.scanPhotoCount = coercion.intValue(from: photos["count"])
                    update.scanPhotoBytes = coercion.int64Value(from: photos["bytes"])
                } else {
                    update.scanPhotoCount = coercion.intValue(from: payload["photo_count"])
                    update.scanPhotoBytes = coercion.int64Value(from: payload["photo_bytes"])
                }

                if let videos = payload["videos"] as? [String: Any] {
                    update.scanVideoCount = coercion.intValue(from: videos["count"])
                    update.scanVideoBytes = coercion.int64Value(from: videos["bytes"])
                } else {
                    update.scanVideoCount = coercion.intValue(from: payload["video_count"])
                    update.scanVideoBytes = coercion.int64Value(from: payload["video_bytes"])
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
