import Foundation

struct LauncherProgressCounters: Equatable {
    private(set) var scannedCandidateCount = 0
    private(set) var plannedStageAndCommitCount = 0
    private(set) var duplicateNotCopiedCount = 0
    private(set) var copiedCount = 0
    private(set) var verifiedCount = 0
    private(set) var committedCount = 0
    private(set) var preferredTotalCount: Int?
    private(set) var fallbackTotalCount: Int?

    var totalCount: Int? {
        preferredTotalCount ?? fallbackTotalCount
    }

    @discardableResult
    mutating func apply(_ update: ParsedReceiptUpdate) -> Bool {
        var progressChanged = false

        if let scanned = update.scannedCandidateCount {
            let normalized = max(scanned, 0)
            if normalized > scannedCandidateCount {
                scannedCandidateCount = normalized
                progressChanged = true
            }
            preferredTotalCount = maxOptional(preferredTotalCount, normalized)
        }

        if let planned = update.plannedStageAndCommit {
            let normalized = max(planned, 0)
            if normalized > plannedStageAndCommitCount {
                plannedStageAndCommitCount = normalized
                progressChanged = true
            }
        }

        if let duplicates = update.duplicateNotCopied {
            let normalized = max(duplicates, 0)
            if normalized > duplicateNotCopiedCount {
                duplicateNotCopiedCount = normalized
                progressChanged = true
            }
        }

        let hasPlanTotals = update.plannedStageAndCommit != nil || update.duplicateNotCopied != nil || fallbackTotalCount != nil
        if hasPlanTotals {
            let fallback = max(plannedStageAndCommitCount + duplicateNotCopiedCount, 0)
            fallbackTotalCount = maxOptional(fallbackTotalCount, fallback)
        }

        if update.copiedIncrement > 0 {
            copiedCount += update.copiedIncrement
            progressChanged = true
        }
        if update.verifiedIncrement > 0 {
            verifiedCount += update.verifiedIncrement
            progressChanged = true
        }
        if update.committedIncrement > 0 {
            committedCount += update.committedIncrement
            progressChanged = true
        }

        clampCounters()
        return progressChanged
    }

    private mutating func clampCounters() {
        guard let totalCount else {
            return
        }

        copiedCount = min(copiedCount, totalCount)
        verifiedCount = min(verifiedCount, totalCount)
        committedCount = min(committedCount, totalCount)
    }

    private func maxOptional(_ current: Int?, _ candidate: Int) -> Int {
        if let current {
            return max(current, candidate)
        }
        return candidate
    }
}

struct LauncherStatusTextBuilder {
    static func runningStatus(
        phase: LauncherPhase,
        totalCount: Int?,
        scannedCandidateCount: Int,
        copiedCount: Int,
        verifiedCount: Int,
        committedCount: Int,
        now: Date,
        runStartedAt: Date?,
        lastProgressEventAt: Date?,
        heartbeatAfter: TimeInterval = 2.0
    ) -> String {
        let base = baseStatus(
            phase: phase,
            totalCount: totalCount,
            scannedCandidateCount: scannedCandidateCount,
            copiedCount: copiedCount,
            verifiedCount: verifiedCount,
            committedCount: committedCount
        )

        guard shouldShowHeartbeat(
            now: now,
            runStartedAt: runStartedAt,
            lastProgressEventAt: lastProgressEventAt,
            heartbeatAfter: heartbeatAfter
        ) else {
            return base
        }

        return "\(base) Still working... \(elapsedString(now: now, runStartedAt: runStartedAt))"
    }

    static func baseStatus(
        phase: LauncherPhase,
        totalCount: Int?,
        scannedCandidateCount: Int,
        copiedCount: Int,
        verifiedCount: Int,
        committedCount: Int
    ) -> String {
        if let totalCount {
            switch phase {
            case .plan:
                return "Running plan for \(totalCount) files..."
            case .copy:
                return "Running copy \(copiedCount)/\(totalCount) files..."
            case .verify:
                return "Running verify \(verifiedCount)/\(totalCount) files..."
            case .commit:
                return "Running commit \(committedCount)/\(totalCount) files..."
            case .finalize, .finished:
                return "Finalizing ingest..."
            case .idle, .scan:
                return "Running scan..."
            }
        }

        switch phase {
        case .finished:
            return "Finishing ingest..."
        case .finalize:
            return "Finalizing ingest..."
        case .idle:
            return "Starting ingest..."
        case .scan where scannedCandidateCount > 0:
            return "Running scan... \(scannedCandidateCount) files found so far."
        case .plan where scannedCandidateCount > 0:
            return "Running plan for \(scannedCandidateCount) files..."
        default:
            return "Running \(phase.displayName.lowercased())..."
        }
    }

    static func shouldShowHeartbeat(
        now: Date,
        runStartedAt: Date?,
        lastProgressEventAt: Date?,
        heartbeatAfter: TimeInterval
    ) -> Bool {
        guard runStartedAt != nil,
              let lastProgressEventAt else {
            return false
        }

        return now.timeIntervalSince(lastProgressEventAt) > heartbeatAfter
    }

    static func elapsedString(now: Date, runStartedAt: Date?) -> String {
        guard let runStartedAt else {
            return "00:00"
        }

        let elapsed = max(0, Int(now.timeIntervalSince(runStartedAt)))
        let minutes = elapsed / 60
        let seconds = elapsed % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

