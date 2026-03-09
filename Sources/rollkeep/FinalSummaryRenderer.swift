import Foundation

enum RollkeepExitCode: Int32 {
    case success = 0
    case failure = 1
    case verifyFailed = 2
    case scanFailed = 3
    case planFailed = 4
    case copyFailed = 5
    case commitFailed = 6
    case finalizeFailed = 7

    static func resolve(finalStatus: String, failurePhase: IngestPhase?) -> RollkeepExitCode {
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

struct FinalSummaryPhaseTiming {
    let phase: IngestPhase
    let milliseconds: Int
}

struct FinalSummaryCounts {
    let candidates: Int
    let photos: Int
    let videos: Int
    let copied: Int
    let verified: Int
    let committed: Int
    let duplicateNotCopied: Int
    let conflictsRenamed: Int
    let errors: Int
}

struct FinalSummaryPayload {
    let sessionID: String
    let finalStatus: String
    let exitCode: Int32
    let dryRun: Bool
    let verificationEnabled: Bool
    let receiptPath: String
    let receiptSink: ReceiptSink.Kind
    let stagingSessionPath: String
    let markdownSummaryPath: String?
    let failurePhase: IngestPhase?
    let failureReason: String?
    let firstErrors: [String]
    let phaseTimings: [FinalSummaryPhaseTiming]
    let counts: FinalSummaryCounts
}

struct FinalSummaryRenderer {
    func renderHuman(_ payload: FinalSummaryPayload) -> String {
        var lines: [String] = []
        lines.append("Rollkeep Final Summary")
        lines.append("Session: \(payload.sessionID)")
        lines.append("Status: \(statusLabel(for: payload))")
        lines.append("Exit code: \(payload.exitCode)")
        lines.append("Receipt: \(payload.receiptPath) [\(payload.receiptSink.rawValue)]")
        if let markdownSummaryPath = payload.markdownSummaryPath {
            lines.append("Markdown summary: \(markdownSummaryPath)")
        }
        lines.append("")

        lines.append("Phase Timings")
        for timing in payload.phaseTimings {
            let seconds = String(format: "%.3fs", Double(timing.milliseconds) / 1_000.0)
            lines.append("- \(timing.phase.rawValue): \(seconds)")
        }
        lines.append("")

        lines.append("Counts")
        lines.append("- candidates: \(payload.counts.candidates) (photos: \(payload.counts.photos), videos: \(payload.counts.videos))")
        lines.append("- copied: \(payload.counts.copied), verified: \(payload.counts.verified), committed: \(payload.counts.committed)")
        lines.append("- duplicate_not_copied: \(payload.counts.duplicateNotCopied), conflicts_renamed: \(payload.counts.conflictsRenamed)")
        lines.append("- errors: \(payload.counts.errors)")

        if payload.finalStatus == "aborted" {
            lines.append("")
            lines.append("Failure")
            if let failurePhase = payload.failurePhase {
                lines.append("- phase: \(failurePhase.rawValue)")
            }
            if let failureReason = payload.failureReason {
                lines.append("- reason: \(failureReason)")
            }
            lines.append("- staging: \(payload.stagingSessionPath)")
            lines.append("- receipt: \(payload.receiptPath)")

            if !payload.firstErrors.isEmpty {
                lines.append("- first_errors:")
                for (index, error) in payload.firstErrors.enumerated() {
                    lines.append("  \(index + 1). \(error)")
                }
            }
        }

        return lines.joined(separator: "\n")
    }

    func renderJSON(_ payload: FinalSummaryPayload) -> String {
        let output: [String: Any] = [
            "session_id": payload.sessionID,
            "status": payload.finalStatus,
            "status_label": statusLabel(for: payload),
            "exit_code": payload.exitCode,
            "dry_run": payload.dryRun,
            "verification_enabled": payload.verificationEnabled,
            "receipt": [
                "path": payload.receiptPath,
                "sink": payload.receiptSink.rawValue,
            ],
            "markdown_summary_path": payload.markdownSummaryPath ?? "not_written",
            "staging_session_path": payload.stagingSessionPath,
            "failure": [
                "phase": payload.failurePhase?.rawValue ?? "none",
                "reason": payload.failureReason ?? "none",
                "first_errors": payload.firstErrors,
            ],
            "phase_timings_ms": payload.phaseTimings.map { timing in
                [
                    "phase": timing.phase.rawValue,
                    "milliseconds": timing.milliseconds,
                ]
            },
            "counts": [
                "candidates": payload.counts.candidates,
                "photos": payload.counts.photos,
                "videos": payload.counts.videos,
                "copied": payload.counts.copied,
                "verified": payload.counts.verified,
                "committed": payload.counts.committed,
                "duplicate_not_copied": payload.counts.duplicateNotCopied,
                "conflicts_renamed": payload.counts.conflictsRenamed,
                "errors": payload.counts.errors,
            ],
        ]

        guard JSONSerialization.isValidJSONObject(output),
              let data = try? JSONSerialization.data(withJSONObject: output, options: [.sortedKeys, .prettyPrinted]),
              let json = String(data: data, encoding: .utf8) else {
            return "{\"status\":\"\(payload.finalStatus)\",\"session_id\":\"\(payload.sessionID)\"}"
        }

        return json
    }

    private func statusLabel(for payload: FinalSummaryPayload) -> String {
        if payload.finalStatus == "aborted" {
            return "FAILED"
        }
        if payload.dryRun {
            return "DRY RUN (scan+plan)"
        }
        if payload.verificationEnabled {
            return "VERIFIED"
        }
        return "COMPLETED (verification skipped)"
    }
}

struct PhaseTimingTracker {
    private var millisecondsByPhase: [IngestPhase: Int] = [:]

    mutating func capture(_ phase: IngestPhase, startedAt: Date) {
        let elapsedMs = Int((Date().timeIntervalSince(startedAt) * 1_000).rounded())
        add(phase, milliseconds: max(0, elapsedMs))
    }

    mutating func add(_ phase: IngestPhase, milliseconds: Int) {
        millisecondsByPhase[phase, default: 0] += milliseconds
    }

    func value(for phase: IngestPhase) -> Int {
        millisecondsByPhase[phase] ?? 0
    }

    func allPhases() -> [FinalSummaryPhaseTiming] {
        IngestPhase.allCases.map { phase in
            FinalSummaryPhaseTiming(phase: phase, milliseconds: value(for: phase))
        }
    }
}
