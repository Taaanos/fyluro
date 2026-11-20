import Foundation
import FyluroCore
import FyluroEngine

enum FyluroExitCode: Int32 {
    case success = 0
    case failure = 1
    case verifyFailed = 2
    case scanFailed = 3
    case planFailed = 4
    case copyFailed = 5
    case commitFailed = 6
    case finalizeFailed = 7

    static func resolve(finalStatus: String, failurePhase: IngestPhase?) -> FyluroExitCode {
        guard finalStatus == "aborted" else {
            return .success
        }

        guard let phase = failurePhase else {
            return .failure
        }

        switch phase {
        case .verify:
            return .verifyFailed
        case .scan:
            return .scanFailed
        case .plan:
            return .planFailed
        case .copy:
            return .copyFailed
        case .commit:
            return .commitFailed
        case .finalize:
            return .finalizeFailed
        }
    }
}

struct FinalSummaryRenderer {
    func renderHuman(_ result: IngestSessionResult, exitCode: Int32) -> String {
        var lines: [String] = []
        lines.append("Fyluro Final Summary")
        lines.append("Session: \(TerminalTextSanitizer.sanitize(result.sessionID))")
        lines.append("Status: \(statusLabel(for: result))")
        lines.append("Idempotency: \(idempotencyLabel(for: result))")
        lines.append("Exit code: \(exitCode)")
        lines.append("Receipt: \(TerminalTextSanitizer.sanitize(result.receiptPath)) [\(TerminalTextSanitizer.sanitize(result.receiptSink))]")
        if let pdfSummaryPath = result.pdfSummaryPath {
            lines.append("PDF summary: \(TerminalTextSanitizer.sanitize(pdfSummaryPath))")
        }
        lines.append("")

        lines.append("Phase Timings")
        for timing in result.phaseTimings {
            let seconds = String(format: "%.3fs", Double(timing.milliseconds) / 1_000.0)
            lines.append("- \(timing.phase.rawValue): \(seconds)")
        }
        lines.append("")

        lines.append("Counts")
        lines.append("- candidates: \(result.counts.candidates) (photos: \(result.counts.photos), videos: \(result.counts.videos), audio: \(result.counts.audios))")
        lines.append("- copied: \(result.counts.copied), verified: \(result.counts.verified), committed: \(result.counts.committed)")
        lines.append("- duplicate_not_copied: \(result.counts.duplicateNotCopied), conflicts_renamed: \(result.counts.conflictsRenamed)")
        lines.append("- errors: \(result.counts.errors)")

        if result.finalStatus == "aborted" {
            lines.append("")
            lines.append("Failure")
            if let failurePhase = result.failurePhase {
                lines.append("- phase: \(failurePhase.rawValue)")
            }
            if let failureReason = result.failureReason {
                lines.append("- reason: \(TerminalTextSanitizer.sanitize(failureReason))")
            }
            lines.append("- staging: \(TerminalTextSanitizer.sanitize(result.stagingSessionPath))")
            lines.append("- receipt: \(TerminalTextSanitizer.sanitize(result.receiptPath))")

            if !result.firstErrors.isEmpty {
                lines.append("- first_errors:")
                for (index, error) in result.firstErrors.enumerated() {
                    lines.append("  \(index + 1). \(TerminalTextSanitizer.sanitize(error))")
                }
            }
        }

        return lines.joined(separator: "\n")
    }

    func renderJSON(_ result: IngestSessionResult, exitCode: Int32) -> String {
        let idempotency = result.idempotency
        let output: [String: Any] = [
            "session_id": result.sessionID,
            "status": result.finalStatus,
            "status_label": statusLabel(for: result),
            "idempotency": [
                "classification": idempotency.classification,
                "new_files_committed": idempotency.newFilesCommitted,
                "duplicates_skipped": idempotency.duplicatesSkipped,
            ],
            "exit_code": exitCode,
            "dry_run": result.dryRun,
            "receipt": [
                "path": result.receiptPath,
                "sink": result.receiptSink,
            ],
            "pdf_summary_path": result.pdfSummaryPath ?? "not_written",
            "staging_session_path": result.stagingSessionPath,
            "failure": [
                "phase": result.failurePhase?.rawValue ?? "none",
                "reason": result.failureReason ?? "none",
                "first_errors": result.firstErrors,
            ],
            "phase_timings_ms": result.phaseTimings.map { timing in
                [
                    "phase": timing.phase.rawValue,
                    "milliseconds": timing.milliseconds,
                ]
            },
            "counts": [
                "candidates": result.counts.candidates,
                "photos": result.counts.photos,
                "videos": result.counts.videos,
                "audio": result.counts.audios,
                "copied": result.counts.copied,
                "verified": result.counts.verified,
                "committed": result.counts.committed,
                "duplicate_not_copied": result.counts.duplicateNotCopied,
                "conflicts_renamed": result.counts.conflictsRenamed,
                "errors": result.counts.errors,
            ],
        ]

        guard JSONSerialization.isValidJSONObject(output),
              let data = try? JSONSerialization.data(withJSONObject: output, options: [.sortedKeys, .prettyPrinted]),
              let json = String(data: data, encoding: .utf8) else {
            return "{\"status\":\"\(result.finalStatus)\",\"session_id\":\"\(result.sessionID)\"}"
        }

        return json
    }

    private func statusLabel(for result: IngestSessionResult) -> String {
        if result.finalStatus == "aborted" {
            return "FAILED"
        }
        if result.dryRun {
            return "DRY RUN (scan+plan)"
        }
        return "VERIFIED"
    }

    private func idempotencyLabel(for result: IngestSessionResult) -> String {
        let summary = result.idempotency
        return "\(summary.classification) (new_files_committed: \(summary.newFilesCommitted), duplicates_skipped: \(summary.duplicatesSkipped))"
    }
}
