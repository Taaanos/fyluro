import Foundation

struct LauncherImportPresentation {
    static func phaseDescription(for phase: LauncherPhase) -> String {
        switch phase {
        case .idle:
            return "Preparing import"
        case .scan:
            return "Scanning source media"
        case .plan:
            return "Planning destination layout"
        case .copy:
            return "Creating verified copy"
        case .verify:
            return "Verifying copied files"
        case .commit:
            return "Saving files to library"
        case .finalize, .finished:
            return "Finalizing receipt"
        }
    }

    static func progressFraction(
        phase: LauncherPhase,
        totalCount: Int?,
        copiedCount: Int,
        verifiedCount: Int,
        committedCount: Int,
        isSuccess: Bool
    ) -> Double {
        if isSuccess {
            return 1.0
        }

        guard let totalCount, totalCount > 0 else {
            switch phase {
            case .idle:
                return 0.0
            case .scan:
                return 0.05
            case .plan:
                return 0.18
            case .copy:
                return 0.35
            case .verify:
                return 0.65
            case .commit:
                return 0.85
            case .finalize, .finished:
                return 0.97
            }
        }

        let total = Double(totalCount)
        let copied = min(max(Double(copiedCount), 0), total)
        let verified = min(max(Double(verifiedCount), 0), total)
        let committed = min(max(Double(committedCount), 0), total)

        switch phase {
        case .idle:
            return 0.0
        case .scan:
            return 0.08
        case .plan:
            return 0.18
        case .copy:
            return 0.18 + (copied / total) * 0.47
        case .verify:
            return 0.65 + (verified / total) * 0.20
        case .commit:
            return 0.85 + (committed / total) * 0.13
        case .finalize, .finished:
            return 0.98
        }
    }

    static func estimatedRemainingText(
        now: Date,
        runStartedAt: Date?,
        phase: LauncherPhase,
        copiedCount: Int,
        progressFraction: Double
    ) -> String {
        guard let runStartedAt else {
            return "Estimating time remaining"
        }

        guard copiedCount > 0, phase != .scan else {
            return "Estimating time remaining"
        }

        let elapsed = now.timeIntervalSince(runStartedAt)
        guard elapsed > 0, progressFraction > 0.02, progressFraction < 0.995 else {
            return "Estimating time remaining"
        }

        let remainingSeconds = elapsed * ((1 - progressFraction) / progressFraction)
        return "About \(durationText(seconds: remainingSeconds)) remaining"
    }

    static func completionDurationText(milliseconds: Int) -> String {
        let seconds = Double(max(milliseconds, 0)) / 1_000.0
        let rounded = max(0, Int(seconds.rounded()))
        let minutes = rounded / 60
        let leftoverSeconds = rounded % 60

        if minutes == 0 {
            return "Elapsed time \(leftoverSeconds)s"
        }

        return String(format: "Elapsed time %dm %02ds", minutes, leftoverSeconds)
    }

    static func scanHeartbeatText(now: Date, lastProgressEventAt: Date?) -> String {
        guard let lastProgressEventAt else {
            return "Last activity: just now"
        }

        let secondsSinceLastActivity = max(0, Int(now.timeIntervalSince(lastProgressEventAt)))
        if secondsSinceLastActivity <= 2 {
            return "Last activity: just now"
        }
        if secondsSinceLastActivity <= 7 {
            return "Last activity: \(secondsSinceLastActivity)s ago"
        }

        return "Still scanning large folder tree... Last activity \(clockDuration(seconds: secondsSinceLastActivity)) ago"
    }

    private static func durationText(seconds: TimeInterval) -> String {
        let rounded = max(0, Int(seconds.rounded()))
        if rounded < 5 {
            return "a few seconds"
        }
        if rounded < 60 {
            return "\(rounded) seconds"
        }
        let minutes = rounded / 60
        let leftoverSeconds = rounded % 60
        if minutes >= 60 {
            let hours = minutes / 60
            let leftoverMinutes = minutes % 60
            if leftoverMinutes == 0 {
                return hours == 1 ? "1 hour" : "\(hours) hours"
            }
            return "\(hours)h \(leftoverMinutes)m"
        }
        if leftoverSeconds < 10 {
            return minutes == 1 ? "1 minute" : "\(minutes) minutes"
        }
        return "\(minutes)m \(leftoverSeconds)s"
    }

    private static func clockDuration(seconds: Int) -> String {
        let normalized = max(0, seconds)
        let minutes = normalized / 60
        let leftoverSeconds = normalized % 60
        return String(format: "%02d:%02d", minutes, leftoverSeconds)
    }
}

