import Foundation

struct LauncherImportPresentation {
    static func phaseDescription(for phase: LauncherPhase) -> String {
        switch phase {
        case .idle:
            return "Preparing import…"
        case .scan:
            return "Scanning source media…"
        case .plan:
            return "Planning folder layout…"
        case .copy:
            return "Copying files…"
        case .verify:
            return "Verifying copied files…"
        case .commit:
            return "Adding files to library…"
        case .finalize, .finished:
            return "Writing receipt…"
        }
    }

    // Progress-bar band layout. Copy and verify run as two sequential passes in
    // the engine (Pass 1 copies all files to staging, Pass 2 verifies all staged
    // files from physical media), so they get equal 34% bands driven by
    // byte-accurate progress.
    private static let scanBandTop = 0.15
    private static let planBand = 0.17
    private static let copyBandStart = 0.18
    private static let copyBandTop = 0.52
    private static let verifyBandStart = 0.52
    private static let verifyBandTop = 0.86
    private static let commitBandTop = 0.98

    static func progressFraction(
        phase: LauncherPhase,
        totalCount: Int?,
        copiedCount: Int,
        verifiedCount: Int,
        committedCount: Int,
        isSuccess: Bool,
        copyByteFraction: Double? = nil,
        verifyByteFraction: Double? = nil,
        scanFraction: Double? = nil
    ) -> Double {
        if isSuccess {
            return 1.0
        }

        let clampedScan = scanFraction.map { min(max($0, 0), 1) }

        guard let totalCount, totalCount > 0 else {
            switch phase {
            case .idle:
                return 0.0
            case .scan:
                return (clampedScan.map { $0 * scanBandTop }) ?? 0.05
            case .plan:
                return planBand
            case .copy:
                return 0.35
            case .verify:
                return 0.69
            case .commit:
                return 0.9
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
            return (clampedScan ?? 0.5) * scanBandTop
        case .plan:
            return planBand
        case .copy:
            let copyProgress = copyByteFraction.map { min(max($0, 0), 1) } ?? (copied / total)
            return copyBandStart + copyProgress * (copyBandTop - copyBandStart)
        case .verify:
            let verifyProgress = verifyByteFraction.map { min(max($0, 0), 1) } ?? (verified / total)
            return verifyBandStart + verifyProgress * (verifyBandTop - verifyBandStart)
        case .commit:
            return verifyBandTop + (committed / total) * (commitBandTop - verifyBandTop)
        case .finalize, .finished:
            return commitBandTop
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
            return "Estimating time remaining…"
        }

        guard copiedCount > 0, phase != .scan else {
            return "Estimating time remaining…"
        }

        let elapsed = now.timeIntervalSince(runStartedAt)
        guard elapsed > 0, progressFraction > 0.02, progressFraction < 0.995 else {
            return "Estimating time remaining…"
        }

        let remainingSeconds = elapsed * ((1 - progressFraction) / progressFraction)
        return "About \(durationText(seconds: remainingSeconds)) remaining"
    }

    static func completionDurationText(milliseconds: Int) -> String {
        "Elapsed time \(elapsedValueText(milliseconds: milliseconds))"
    }

    static func elapsedValueText(milliseconds: Int) -> String {
        let seconds = Double(max(milliseconds, 0)) / 1_000.0
        let rounded = max(0, Int(seconds.rounded()))
        let minutes = rounded / 60
        let leftoverSeconds = rounded % 60

        if minutes == 0 {
            return "\(leftoverSeconds)s"
        }

        return String(format: "%dm %02ds", minutes, leftoverSeconds)
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

        return "Still scanning folders… Last activity \(elapsedValueText(milliseconds: secondsSinceLastActivity * 1_000)) ago"
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
}

