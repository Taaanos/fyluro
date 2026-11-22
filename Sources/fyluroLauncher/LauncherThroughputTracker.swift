import Foundation

enum LauncherThroughputPhase: Equatable, Sendable {
    case copy
    case verify

    var displayName: String {
        switch self {
        case .copy:
            return "Copy"
        case .verify:
            return "Verify"
        }
    }
}

struct LauncherThroughputSample: Equatable, Sendable {
    let elapsedSeconds: TimeInterval
    let phase: LauncherThroughputPhase
    let bytesPerSecond: Double
}

struct LauncherThroughputBucket: Equatable, Sendable {
    let phase: LauncherThroughputPhase
    let startElapsedSeconds: TimeInterval
    let endElapsedSeconds: TimeInterval
    let bytesPerSecond: Double
    let sampleCount: Int

    var isAggregated: Bool {
        sampleCount > 1
    }
}

struct LauncherThroughputTracker: Equatable {
    private struct WindowSample: Equatable {
        let timestamp: Date
        let totalBytes: Int64
        let phase: LauncherThroughputPhase
    }

    static let defaultWarmUpSeconds: TimeInterval = 1.0
    static let defaultSmoothingWindowSeconds: TimeInterval = 3.0
    static let defaultStallThresholdSeconds: TimeInterval = 2.5
    static let minimumLiveTimelineSpanSeconds: TimeInterval = 30.0

    private static let rateFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useBytes, .useKB, .useMB, .useGB, .useTB]
        formatter.countStyle = .file
        formatter.includesUnit = true
        formatter.includesCount = true
        formatter.isAdaptive = true
        return formatter
    }()

    private(set) var samples: [LauncherThroughputSample] = []
    private(set) var totalCopiedBytes: Int64 = 0
    private(set) var totalVerifiedBytes: Int64 = 0
    private(set) var activePhase: LauncherThroughputPhase?

    private var timelineStartedAt: Date?
    private var copyPhaseStartedAt: Date?
    private var copyPhaseEndedAt: Date?
    private var verifyPhaseStartedAt: Date?
    private var verifyPhaseEndedAt: Date?
    private var lastSampleAt: Date?
    private var lastSampledCopiedBytes: Int64 = 0
    private var lastSampledVerifiedBytes: Int64 = 0
    private var lastProgressByteEventAt: Date?
    private var smoothedWindowSamples: [WindowSample] = []
    private var finalizedCopyDurationMs: Int?
    private var finalizedVerifyDurationMs: Int?

    var hasTelemetryData: Bool {
        !samples.isEmpty || totalCopiedBytes > 0 || totalVerifiedBytes > 0
    }

    var timelineDurationSeconds: TimeInterval {
        max(samples.last?.elapsedSeconds ?? 0, 0)
    }

    var averageCopyBytesPerSecond: Double? {
        guard totalCopiedBytes > 0, let seconds = copyDurationSeconds, seconds > 0 else {
            return nil
        }
        return Double(totalCopiedBytes) / seconds
    }

    var averageVerifyBytesPerSecond: Double? {
        guard totalVerifiedBytes > 0, let seconds = verifyDurationSeconds, seconds > 0 else {
            return nil
        }
        return Double(totalVerifiedBytes) / seconds
    }

    mutating func reset() {
        self = LauncherThroughputTracker()
    }

    mutating func enterPhase(_ phase: LauncherPhase, at now: Date) {
        switch phase {
        case .copy:
            guard activePhase != .copy else { return }
            if timelineStartedAt == nil {
                timelineStartedAt = now
            }
            if copyPhaseStartedAt == nil {
                copyPhaseStartedAt = now
            }
            activePhase = .copy
            lastSampleAt = lastSampleAt ?? now
            smoothedWindowSamples = [WindowSample(timestamp: now, totalBytes: totalCopiedBytes, phase: .copy)]

        case .verify:
            guard activePhase != .verify else { return }
            if activePhase == .copy {
                flushSample(for: .copy, at: now, minimumInterval: 0.05)
                copyPhaseEndedAt = copyPhaseEndedAt ?? now
            }
            if timelineStartedAt == nil {
                timelineStartedAt = now
            }
            if verifyPhaseStartedAt == nil {
                verifyPhaseStartedAt = now
            }
            activePhase = .verify
            lastSampleAt = now
            smoothedWindowSamples = [WindowSample(timestamp: now, totalBytes: totalVerifiedBytes, phase: .verify)]

        case .commit, .finalize, .finished:
            if let current = activePhase {
                flushSample(for: current, at: now, minimumInterval: 0.05)
                closePhase(current, at: now)
            }
            activePhase = nil
            smoothedWindowSamples = []

        case .idle, .scan, .plan:
            break
        }
    }

    mutating func recordCopiedBytes(_ totalBytes: Int64, at now: Date) {
        if activePhase != .copy {
            enterPhase(.copy, at: now)
        }
        let clamped = max(totalCopiedBytes, totalBytes)
        if clamped > totalCopiedBytes {
            lastProgressByteEventAt = now
        }
        totalCopiedBytes = clamped
        appendSmoothedSample(totalBytes: clamped, phase: .copy, at: now)
    }

    mutating func recordVerifiedBytes(_ totalBytes: Int64, at now: Date) {
        if activePhase != .verify {
            enterPhase(.verify, at: now)
        }
        let clamped = max(totalVerifiedBytes, totalBytes)
        if clamped > totalVerifiedBytes {
            lastProgressByteEventAt = now
        }
        totalVerifiedBytes = clamped
        appendSmoothedSample(totalBytes: clamped, phase: .verify, at: now)
    }

    mutating func recordTick(at now: Date) {
        guard let phase = activePhase else {
            return
        }
        flushSample(for: phase, at: now, minimumInterval: 0.05)
    }

    mutating func finalize(
        at now: Date,
        copyDurationMs: Int? = nil,
        verifyDurationMs: Int? = nil
    ) {
        if let current = activePhase {
            flushSample(for: current, at: now, minimumInterval: 0.05)
            closePhase(current, at: now)
        }
        activePhase = nil
        smoothedWindowSamples = []
        if let copyDurationMs, copyDurationMs > 0 {
            finalizedCopyDurationMs = copyDurationMs
        }
        if let verifyDurationMs, verifyDurationMs > 0 {
            finalizedVerifyDurationMs = verifyDurationMs
        }
    }

    func liveBytesPerSecond(
        at now: Date,
        warmUpSeconds: TimeInterval = LauncherThroughputTracker.defaultWarmUpSeconds
    ) -> Double? {
        guard let phase = activePhase else {
            return nil
        }

        let phaseStart: Date?
        let totalBytes: Int64
        switch phase {
        case .copy:
            phaseStart = copyPhaseStartedAt
            totalBytes = totalCopiedBytes
        case .verify:
            phaseStart = verifyPhaseStartedAt
            totalBytes = totalVerifiedBytes
        }

        guard let phaseStart else {
            return nil
        }

        let phaseElapsed = now.timeIntervalSince(phaseStart)
        guard phaseElapsed >= warmUpSeconds, totalBytes > 0 else {
            return nil
        }

        if let lastProgressByteEventAt,
           now.timeIntervalSince(lastProgressByteEventAt) >= Self.defaultStallThresholdSeconds {
            return 0
        }

        let matching = smoothedWindowSamples.filter { $0.phase == phase }
        if let oldest = matching.first, let newest = matching.last {
            let span = newest.timestamp.timeIntervalSince(oldest.timestamp)
            if span >= 0.4 {
                let delta = max(0, newest.totalBytes - oldest.totalBytes)
                return Double(delta) / span
            }
        }

        return Double(totalBytes) / phaseElapsed
    }

    static func buckets(
        from samples: [LauncherThroughputSample],
        maxBuckets: Int
    ) -> [LauncherThroughputBucket] {
        guard !samples.isEmpty else {
            return []
        }

        let targetBuckets = max(1, maxBuckets)
        if samples.count <= targetBuckets {
            return samples.map { sample in
                LauncherThroughputBucket(
                    phase: sample.phase,
                    startElapsedSeconds: sample.elapsedSeconds,
                    endElapsedSeconds: sample.elapsedSeconds,
                    bytesPerSecond: sample.bytesPerSecond,
                    sampleCount: 1
                )
            }
        }

        // Split by contiguous phase so Copy and Verify samples are never
        // averaged across the phase boundary.
        var runs: [[LauncherThroughputSample]] = []
        for sample in samples {
            if var last = runs.last, last.first?.phase == sample.phase {
                last.append(sample)
                runs[runs.count - 1] = last
            } else {
                runs.append([sample])
            }
        }

        let totalCount = samples.count
        var result: [LauncherThroughputBucket] = []
        result.reserveCapacity(targetBuckets)

        var remainingBuckets = max(targetBuckets, runs.count)
        for (index, run) in runs.enumerated() {
            let runsLeft = runs.count - index - 1
            let proportional = Int((Double(run.count) / Double(totalCount) * Double(targetBuckets)).rounded())
            let runBucketCount = min(
                run.count,
                max(1, min(proportional, remainingBuckets - runsLeft))
            )
            remainingBuckets -= runBucketCount
            result.append(contentsOf: downsample(run: run, bucketCount: runBucketCount))
        }

        return result
    }

    static func formattedRate(_ bytesPerSecond: Double) -> String {
        guard bytesPerSecond.isFinite, bytesPerSecond >= 1 else {
            return "0 B/s"
        }
        let rounded = Int64(bytesPerSecond.rounded())
        return "\(rateFormatter.string(fromByteCount: rounded))/s"
    }

    static func niceAxisCeiling(for peakBytesPerSecond: Double) -> Double {
        let minimumCeiling: Double = 1_000_000 // 1 MB/s floor keeps quiet graphs readable.
        guard peakBytesPerSecond.isFinite, peakBytesPerSecond > 0 else {
            return minimumCeiling
        }
        let target = max(peakBytesPerSecond * 1.05, minimumCeiling)
        let exponent = floor(log10(target))
        let magnitude = pow(10.0, exponent)
        let normalized = target / magnitude
        let steps: [Double] = [1.0, 1.2, 1.5, 2.0, 2.5, 3.0, 4.0, 5.0, 6.0, 8.0, 10.0]
        let chosen = steps.first(where: { $0 >= normalized }) ?? 10.0
        return chosen * magnitude
    }

    static func formattedElapsed(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60

        if hours > 0 {
            return String(format: "%dh %02dm", hours, minutes)
        }
        if minutes > 0 {
            return String(format: "%dm %02ds", minutes, secs)
        }
        return "\(secs)s"
    }

    private var copyDurationSeconds: TimeInterval? {
        if let ms = finalizedCopyDurationMs, ms > 0 {
            return Double(ms) / 1_000.0
        }
        guard let start = copyPhaseStartedAt else { return nil }
        let end = copyPhaseEndedAt ?? lastSampleAt ?? start
        let duration = end.timeIntervalSince(start)
        return duration > 0 ? duration : nil
    }

    private var verifyDurationSeconds: TimeInterval? {
        if let ms = finalizedVerifyDurationMs, ms > 0 {
            return Double(ms) / 1_000.0
        }
        guard let start = verifyPhaseStartedAt else { return nil }
        let end = verifyPhaseEndedAt ?? lastSampleAt ?? start
        let duration = end.timeIntervalSince(start)
        return duration > 0 ? duration : nil
    }

    private mutating func closePhase(_ phase: LauncherThroughputPhase, at now: Date) {
        switch phase {
        case .copy:
            copyPhaseEndedAt = copyPhaseEndedAt ?? now
        case .verify:
            verifyPhaseEndedAt = verifyPhaseEndedAt ?? now
        }
    }

    private mutating func flushSample(
        for phase: LauncherThroughputPhase,
        at now: Date,
        minimumInterval: TimeInterval
    ) {
        guard let timelineStartedAt else {
            return
        }
        let previousTime = lastSampleAt ?? timelineStartedAt
        let dt = now.timeIntervalSince(previousTime)
        guard dt >= minimumInterval else {
            return
        }

        let deltaBytes: Int64
        switch phase {
        case .copy:
            deltaBytes = max(0, totalCopiedBytes - lastSampledCopiedBytes)
            lastSampledCopiedBytes = totalCopiedBytes
        case .verify:
            deltaBytes = max(0, totalVerifiedBytes - lastSampledVerifiedBytes)
            lastSampledVerifiedBytes = totalVerifiedBytes
        }

        lastSampleAt = now
        let elapsed = max(0, now.timeIntervalSince(timelineStartedAt))
        let rate = Double(deltaBytes) / dt
        samples.append(LauncherThroughputSample(
            elapsedSeconds: elapsed,
            phase: phase,
            bytesPerSecond: rate
        ))
    }

    private mutating func appendSmoothedSample(
        totalBytes: Int64,
        phase: LauncherThroughputPhase,
        at now: Date
    ) {
        smoothedWindowSamples.append(WindowSample(timestamp: now, totalBytes: totalBytes, phase: phase))
        let cutoff = now.addingTimeInterval(-Self.defaultSmoothingWindowSeconds)
        // Retain one sample before the cutoff so the window span covers the full interval.
        if let firstInsideIndex = smoothedWindowSamples.firstIndex(where: { $0.timestamp >= cutoff }),
           firstInsideIndex > 1 {
            smoothedWindowSamples.removeFirst(firstInsideIndex - 1)
        }
    }

    private static func downsample(
        run: [LauncherThroughputSample],
        bucketCount: Int
    ) -> [LauncherThroughputBucket] {
        guard let phase = run.first?.phase, bucketCount > 0 else {
            return []
        }

        var buckets: [LauncherThroughputBucket] = []
        buckets.reserveCapacity(bucketCount)

        for bucketIndex in 0..<bucketCount {
            let startIdx = bucketIndex * run.count / bucketCount
            let endIdx = max(startIdx + 1, (bucketIndex + 1) * run.count / bucketCount)
            let slice = run[startIdx..<min(endIdx, run.count)]
            guard let first = slice.first, let last = slice.last else { continue }
            let sumRate = slice.reduce(0.0) { $0 + $1.bytesPerSecond }
            let averageRate = sumRate / Double(slice.count)
            buckets.append(LauncherThroughputBucket(
                phase: phase,
                startElapsedSeconds: first.elapsedSeconds,
                endElapsedSeconds: last.elapsedSeconds,
                bytesPerSecond: averageRate,
                sampleCount: slice.count
            ))
        }

        return buckets
    }
}
