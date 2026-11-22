import XCTest
@testable import fyluroLauncher

final class LauncherThroughputTrackerTests: XCTestCase {
    func testLiveRateRespectsWarmUpAndReflectsSlidingWindow() {
        var tracker = LauncherThroughputTracker()
        let start = Date(timeIntervalSince1970: 1_000)

        tracker.enterPhase(.copy, at: start)
        tracker.recordCopiedBytes(50_000_000, at: start.addingTimeInterval(0.5))
        XCTAssertNil(tracker.liveBytesPerSecond(at: start.addingTimeInterval(0.5)))

        tracker.recordCopiedBytes(100_000_000, at: start.addingTimeInterval(1.0))
        let rateAtOneSecond = tracker.liveBytesPerSecond(at: start.addingTimeInterval(1.0))
        XCTAssertNotNil(rateAtOneSecond)
        XCTAssertEqual(rateAtOneSecond ?? 0, 100_000_000, accuracy: 1_000)

        tracker.recordCopiedBytes(200_000_000, at: start.addingTimeInterval(2.0))
        tracker.recordCopiedBytes(250_000_000, at: start.addingTimeInterval(3.0))
        let rateAtThreeSeconds = tracker.liveBytesPerSecond(at: start.addingTimeInterval(3.0))
        XCTAssertEqual(rateAtThreeSeconds ?? 0, 83_333_333, accuracy: 100_000)
    }

    func testStallDropsLiveRateAndTickToZero() {
        var tracker = LauncherThroughputTracker()
        let start = Date(timeIntervalSince1970: 2_000)

        tracker.enterPhase(.copy, at: start)
        tracker.recordCopiedBytes(100_000_000, at: start.addingTimeInterval(1.0))
        tracker.recordTick(at: start.addingTimeInterval(1.0))
        XCTAssertEqual(tracker.samples.last?.bytesPerSecond ?? -1, 100_000_000, accuracy: 1_000)

        tracker.recordTick(at: start.addingTimeInterval(2.0))
        XCTAssertEqual(tracker.samples.last?.bytesPerSecond ?? -1, 0, accuracy: 1)

        let stalledRate = tracker.liveBytesPerSecond(at: start.addingTimeInterval(4.0))
        XCTAssertEqual(stalledRate ?? -1, 0, accuracy: 1)
    }

    func testCopyToVerifyTransitionSeparatesSamplesAndAverages() {
        var tracker = LauncherThroughputTracker()
        let start = Date(timeIntervalSince1970: 3_000)

        tracker.enterPhase(.copy, at: start)
        tracker.recordCopiedBytes(100_000_000, at: start.addingTimeInterval(1.0))
        tracker.recordTick(at: start.addingTimeInterval(1.0))
        tracker.recordCopiedBytes(200_000_000, at: start.addingTimeInterval(2.0))
        tracker.recordTick(at: start.addingTimeInterval(2.0))

        tracker.enterPhase(.verify, at: start.addingTimeInterval(2.0))
        tracker.recordVerifiedBytes(200_000_000, at: start.addingTimeInterval(2.5))
        tracker.recordTick(at: start.addingTimeInterval(3.0))
        tracker.finalize(at: start.addingTimeInterval(3.0), copyDurationMs: 2_000, verifyDurationMs: 1_000)

        XCTAssertEqual(tracker.samples.filter { $0.phase == .copy }.count, 2)
        XCTAssertEqual(tracker.samples.filter { $0.phase == .verify }.count, 1)
        XCTAssertEqual(tracker.averageCopyBytesPerSecond ?? 0, 100_000_000, accuracy: 1_000)
        XCTAssertEqual(tracker.averageVerifyBytesPerSecond ?? 0, 200_000_000, accuracy: 1_000)
        XCTAssertNil(tracker.liveBytesPerSecond(at: start.addingTimeInterval(3.5)))
    }

    func testBucketingDownsamplesLongRunWithoutMixingPhases() {
        var samples: [LauncherThroughputSample] = []
        for second in 1...2_400 {
            samples.append(LauncherThroughputSample(
                elapsedSeconds: TimeInterval(second),
                phase: .copy,
                bytesPerSecond: 120_000_000
            ))
        }
        for second in 2_401...3_600 {
            samples.append(LauncherThroughputSample(
                elapsedSeconds: TimeInterval(second),
                phase: .verify,
                bytesPerSecond: 360_000_000
            ))
        }

        let buckets = LauncherThroughputTracker.buckets(from: samples, maxBuckets: 120)
        XCTAssertEqual(buckets.count, 120)

        let copyBuckets = buckets.filter { $0.phase == .copy }
        let verifyBuckets = buckets.filter { $0.phase == .verify }
        XCTAssertEqual(copyBuckets.count, 80)
        XCTAssertEqual(verifyBuckets.count, 40)

        for bucket in copyBuckets {
            XCTAssertEqual(bucket.bytesPerSecond, 120_000_000, accuracy: 1)
            XCTAssertTrue(bucket.isAggregated)
        }
        for bucket in verifyBuckets {
            XCTAssertEqual(bucket.bytesPerSecond, 360_000_000, accuracy: 1)
            XCTAssertTrue(bucket.isAggregated)
        }

        let wideBuckets = LauncherThroughputTracker.buckets(from: samples, maxBuckets: 240)
        XCTAssertEqual(wideBuckets.count, 240)
    }

    func testFormattingHelpers() {
        XCTAssertEqual(LauncherThroughputTracker.formattedRate(0), "0 B/s")
        XCTAssertEqual(LauncherThroughputTracker.formattedRate(-5), "0 B/s")
        XCTAssertTrue(LauncherThroughputTracker.formattedRate(150_000_000).hasSuffix("/s"))

        XCTAssertEqual(LauncherThroughputTracker.formattedElapsed(0), "0s")
        XCTAssertEqual(LauncherThroughputTracker.formattedElapsed(45), "45s")
        XCTAssertEqual(LauncherThroughputTracker.formattedElapsed(754), "12m 34s")
        XCTAssertEqual(LauncherThroughputTracker.formattedElapsed(3_840), "1h 04m")
    }

    func testNiceAxisCeilingSnapsToCleanSteps() {
        XCTAssertEqual(LauncherThroughputTracker.niceAxisCeiling(for: 0), 1_000_000, accuracy: 1)
        XCTAssertEqual(LauncherThroughputTracker.niceAxisCeiling(for: 99_800_000), 120_000_000, accuracy: 1)
        XCTAssertEqual(LauncherThroughputTracker.niceAxisCeiling(for: 143_600_000), 200_000_000, accuracy: 1)
        XCTAssertEqual(LauncherThroughputTracker.niceAxisCeiling(for: 420_000_000), 500_000_000, accuracy: 1)
    }
}
