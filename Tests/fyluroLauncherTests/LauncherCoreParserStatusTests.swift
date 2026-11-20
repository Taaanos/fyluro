import XCTest
@testable import fyluroLauncher
@testable import FyluroCore

// Progress counters, status text, presentation, and source-scope summary
// behavior. (The CLI stdout / receipt text parsers were removed when the app
// moved to the in-process engine event stream; their coverage now lives in the
// engine and in the app's event-application tests.)
@MainActor
final class LauncherCoreTests: XCTestCase {
    func testLauncherProgressCountersPreferScanAndClampCounters() {
        var counters = LauncherProgressCounters()

        _ = counters.apply(ParsedReceiptUpdate(
            phase: .plan,
            scannedCandidateCount: nil,
            plannedStageAndCommit: 8,
            duplicateNotCopied: 2,
            copiedIncrement: 0,
            verifiedIncrement: 0,
            committedIncrement: 0
        ))
        XCTAssertEqual(counters.totalCount, 10)

        _ = counters.apply(ParsedReceiptUpdate(
            phase: .copy,
            scannedCandidateCount: 12,
            plannedStageAndCommit: nil,
            duplicateNotCopied: nil,
            copiedIncrement: 0,
            verifiedIncrement: 0,
            committedIncrement: 0
        ))
        XCTAssertEqual(counters.totalCount, 12)

        _ = counters.apply(ParsedReceiptUpdate(
            phase: .commit,
            scannedCandidateCount: nil,
            plannedStageAndCommit: nil,
            duplicateNotCopied: nil,
            copiedIncrement: 14,
            verifiedIncrement: 13,
            committedIncrement: 15
        ))

        XCTAssertEqual(counters.copiedCount, 12)
        XCTAssertEqual(counters.verifiedCount, 12)
        XCTAssertEqual(counters.committedCount, 12)
    }

    func testLauncherStatusTextBuilderHeartbeatAfterStall() {
        let now = Date(timeIntervalSince1970: 12)
        let runStartedAt = Date(timeIntervalSince1970: 0)
        let lastProgressEventAt = Date(timeIntervalSince1970: 9)

        let status = LauncherStatusTextBuilder.runningStatus(
            phase: .copy,
            totalCount: 200,
            scannedCandidateCount: 0,
            copiedCount: 7,
            verifiedCount: 0,
            committedCount: 0,
            now: now,
            runStartedAt: runStartedAt,
            lastProgressEventAt: lastProgressEventAt
        )

        XCTAssertEqual(status, "Running copy 7/200 files... Still working... 00:12")
    }

    func testLauncherStatusTextBuilderWithoutHeartbeatWhenRecentProgress() {
        let now = Date(timeIntervalSince1970: 12)
        let runStartedAt = Date(timeIntervalSince1970: 0)
        let lastProgressEventAt = Date(timeIntervalSince1970: 11)

        let status = LauncherStatusTextBuilder.runningStatus(
            phase: .verify,
            totalCount: 200,
            scannedCandidateCount: 0,
            copiedCount: 7,
            verifiedCount: 4,
            committedCount: 0,
            now: now,
            runStartedAt: runStartedAt,
            lastProgressEventAt: lastProgressEventAt
        )

        XCTAssertEqual(status, "Running verify 4/200 files...")
    }

    func testEstimatedRemainingTextStaysEstimatingDuringScan() {
        let message = LauncherImportPresentation.estimatedRemainingText(
            now: Date(timeIntervalSince1970: 60),
            runStartedAt: Date(timeIntervalSince1970: 0),
            phase: .scan,
            copiedCount: 0,
            progressFraction: 0.08
        )

        XCTAssertEqual(message, "Estimating time remaining")
    }

    func testEstimatedRemainingTextUsesElapsedAfterCopyStarts() {
        let message = LauncherImportPresentation.estimatedRemainingText(
            now: Date(timeIntervalSince1970: 80),
            runStartedAt: Date(timeIntervalSince1970: 0),
            phase: .copy,
            copiedCount: 3,
            progressFraction: 0.40
        )

        XCTAssertEqual(message, "About 2 minutes remaining")
    }

    func testScanHeartbeatTextUsesSoftReassuranceThresholds() {
        let now = Date(timeIntervalSince1970: 200)

        XCTAssertEqual(
            LauncherImportPresentation.scanHeartbeatText(
                now: now,
                lastProgressEventAt: Date(timeIntervalSince1970: 199)
            ),
            "Last activity: just now"
        )

        XCTAssertEqual(
            LauncherImportPresentation.scanHeartbeatText(
                now: now,
                lastProgressEventAt: Date(timeIntervalSince1970: 195)
            ),
            "Last activity: 5s ago"
        )

        XCTAssertEqual(
            LauncherImportPresentation.scanHeartbeatText(
                now: now,
                lastProgressEventAt: Date(timeIntervalSince1970: 111)
            ),
            "Still scanning large folder tree... Last activity 01:29 ago"
        )
    }

    func testLauncherSourceScopeSummaryCountsDetectedCamerasExcludingUnknown() {
        let summary = LauncherSourceScopeSummary(snapshot: makeScanProgressSnapshot(
            itemCount: 4,
            photoCount: 3,
            videoCount: 1,
            totalBytes: 3200,
            distribution: [
                CameraDistributionEntry(cameraLabel: "canon-eos-r5", fileCount: 3),
                CameraDistributionEntry(cameraLabel: CameraLabeler.unknownLabel, fileCount: 1),
            ]
        ))

        XCTAssertEqual(summary.itemCount, 4)
        XCTAssertEqual(summary.detectedCameraCount, 1)
        XCTAssertEqual(summary.cameraEntries.map(\.displayLabel), ["canon-eos-r5", "Unknown camera"])
        XCTAssertEqual(summary.cameraEntries.map(\.fileCount), [3, 1])
    }

    func testLauncherSourceScopeSummaryComputesUnsortedCountFromScanSummary() {
        let scanSummary = makeScanSummary(
            itemCount: 4,
            photoCount: 3,
            videoCount: 1,
            totalBytes: 400,
            distribution: [
                CameraDistributionEntry(cameraLabel: "canon-eos-r5", fileCount: 4),
            ],
            unsortedPhotoCount: 2
        )

        let summary = LauncherSourceScopeSummary(summary: scanSummary)

        XCTAssertEqual(summary.unsortedCount, 2)
        XCTAssertEqual(
            summary.unsortedWarningText,
            "2 items will be placed in _unsorted because capture date metadata is missing."
        )
    }

    func testLauncherSourceScopeSummaryHasZeroErrorAndWarningCountsWhenScanSummaryHasNone() {
        let scanSummary = makeScanSummary(
            itemCount: 2,
            photoCount: 2,
            videoCount: 0,
            totalBytes: 200,
            distribution: []
        )

        let summary = LauncherSourceScopeSummary(summary: scanSummary)

        XCTAssertEqual(summary.errorCount, 0)
        XCTAssertEqual(summary.warningCount, 0)
        XCTAssertNil(summary.scanErrorText)
        XCTAssertNil(summary.scanWarningText)
    }

    func testLauncherSourceScopeSummaryComputesErrorCountFromScanSummary() {
        let scanSummary = makeScanSummary(
            itemCount: 2,
            photoCount: 2,
            videoCount: 0,
            totalBytes: 200,
            distribution: [],
            errors: [ScanErrorRecord(path: "/source/DCIM/BAD.JPG", message: "permission denied")]
        )

        let summary = LauncherSourceScopeSummary(summary: scanSummary)

        XCTAssertEqual(summary.errorCount, 1)
        XCTAssertEqual(summary.warningCount, 0)
        XCTAssertEqual(summary.scanErrorText, "1 file couldn't be read and will be skipped.")
        XCTAssertNil(summary.scanWarningText)
    }

    func testLauncherSourceScopeSummaryComputesWarningCountFromScanSummary() {
        let scanSummary = makeScanSummary(
            itemCount: 2,
            photoCount: 2,
            videoCount: 0,
            totalBytes: 200,
            distribution: [],
            warnings: [
                ScanWarningRecord(path: "/source/DCIM/BIG.RAW", message: "unknown large file", fileExtension: "raw", sizeBytes: 999_999_999, category: .unknownLargeSkippedFile),
                ScanWarningRecord(path: "/source/DCIM/LINK.JPG", message: "symbolic link", fileExtension: "jpg", sizeBytes: 0, category: .symbolicLinkSkipped),
            ]
        )

        let summary = LauncherSourceScopeSummary(summary: scanSummary)

        XCTAssertEqual(summary.errorCount, 0)
        XCTAssertEqual(summary.warningCount, 2)
        XCTAssertNil(summary.scanErrorText)
        XCTAssertEqual(summary.scanWarningText, "2 files will be skipped (large or unsupported files).")
    }

    func testLauncherSourceScopeSummaryComputesErrorAndWarningCountsTogetherFromPreparation() {
        let scanSummary = makeScanSummary(
            itemCount: 2,
            photoCount: 2,
            videoCount: 0,
            totalBytes: 200,
            distribution: [],
            errors: [ScanErrorRecord(path: "/source/DCIM/BAD.JPG", message: "permission denied")],
            warnings: [ScanWarningRecord(path: "/source/DCIM/BIG.RAW", message: "unknown large file", fileExtension: "raw", sizeBytes: 999_999_999, category: .unknownLargeSkippedFile)]
        )
        let preparation = makeIngestPreparation(summary: scanSummary)

        let summary = LauncherSourceScopeSummary(preparation: preparation)

        XCTAssertEqual(summary.errorCount, 1)
        XCTAssertEqual(summary.warningCount, 1)
        XCTAssertEqual(summary.scanErrorText, "1 file couldn't be read and will be skipped.")
        XCTAssertEqual(summary.scanWarningText, "1 file will be skipped (large or unsupported files).")
    }

    func testLauncherSourceScopeSummaryUnsortedWarningAppearsOnlyWhenCountIsPositive() {
        let none = LauncherSourceScopeSummary(
            itemCount: 2,
            photoCount: 2,
            videoCount: 0,
            totalBytes: 200,
            unsortedCount: 0
        )
        XCTAssertNil(none.unsortedWarningText)

        let one = LauncherSourceScopeSummary(
            itemCount: 1,
            photoCount: 1,
            videoCount: 0,
            totalBytes: 100,
            unsortedCount: 1
        )
        XCTAssertEqual(
            one.unsortedWarningText,
            "1 item will be placed in _unsorted because capture date metadata is missing."
        )
    }

    func testLauncherSourceScopeSummaryCaptureDateRangeIsNilWhenCandidatesEmpty() {
        let scanSummary = makeScanSummary(
            itemCount: 0,
            photoCount: 0,
            videoCount: 0,
            totalBytes: 0,
            distribution: []
        )

        let summary = LauncherSourceScopeSummary(summary: scanSummary)

        XCTAssertNil(summary.captureDateRange)
    }

    func testLauncherSourceScopeSummaryCaptureDateRangeIsNilWhenAllDatesMissing() {
        let scanSummary = makeScanSummary(
            itemCount: 3,
            photoCount: 3,
            videoCount: 0,
            totalBytes: 300,
            distribution: [
                CameraDistributionEntry(cameraLabel: "canon-eos-r5", fileCount: 3),
            ],
            unsortedPhotoCount: 3
        )

        let summary = LauncherSourceScopeSummary(summary: scanSummary)

        XCTAssertNil(summary.captureDateRange)
    }

    func testLauncherSourceScopeSummaryCaptureDateRangeSingleDate() {
        let date = makeDate(year: 2026, month: 7, day: 2)
        let scanSummary = makeDatedScanSummary(dates: [date])

        let summary = LauncherSourceScopeSummary(summary: scanSummary)

        XCTAssertEqual(summary.captureDateRange?.start, date)
        XCTAssertEqual(summary.captureDateRange?.end, date)
    }

    func testLauncherSourceScopeSummaryCaptureDateRangeMultiDay() {
        let start = makeDate(year: 2026, month: 7, day: 2)
        let end = makeDate(year: 2026, month: 7, day: 14)
        let scanSummary = makeDatedScanSummary(dates: [end, start, makeDate(year: 2026, month: 7, day: 8)])

        let summary = LauncherSourceScopeSummary(summary: scanSummary)

        XCTAssertEqual(summary.captureDateRange?.start, start)
        XCTAssertEqual(summary.captureDateRange?.end, end)
    }

    func testLauncherSourceScopeSummaryCaptureDateRangeTextIsNilDuringLiveScanning() {
        let viewModel = LauncherViewModel(
            destinationRemembering: StubLauncherDestinationRemembering(initialPath: nil),
            destinationDefaulting: StubLauncherDestinationDefaulting(path: nil)
        )
        viewModel.sourceScanState = .scanning(LauncherSourceScopeSummary(snapshot: makeScanProgressSnapshot(
            itemCount: 2,
            photoCount: 2,
            videoCount: 0,
            totalBytes: 200,
            distribution: []
        )))

        XCTAssertNil(viewModel.setupInventoryCaptureDateRangeText)
    }

    func testLauncherSourceScopeSummaryCaptureDateRangeTextFormatsSameDayAsSingleDate() {
        let start = makeDate(year: 2026, month: 7, day: 2, hour: 9)
        let end = makeDate(year: 2026, month: 7, day: 2, hour: 17)
        let summary = LauncherSourceScopeSummary(summary: makeDatedScanSummary(dates: [start, end]))

        let viewModel = LauncherViewModel(
            destinationRemembering: StubLauncherDestinationRemembering(initialPath: nil),
            destinationDefaulting: StubLauncherDestinationDefaulting(path: nil)
        )
        viewModel.sourceScanState = .ready(summary)

        XCTAssertEqual(
            viewModel.setupInventoryCaptureDateRangeText,
            LauncherViewModel.captureDateRangeDayYearFormatter.string(from: start)
        )
    }

    func testLauncherSourceScopeSummaryCaptureDateRangeTextFormatsSameYearRangeWithYearOnce() {
        let start = makeDate(year: 2026, month: 7, day: 2)
        let end = makeDate(year: 2026, month: 7, day: 14)
        let summary = LauncherSourceScopeSummary(summary: makeDatedScanSummary(dates: [start, end]))

        let viewModel = LauncherViewModel(
            destinationRemembering: StubLauncherDestinationRemembering(initialPath: nil),
            destinationDefaulting: StubLauncherDestinationDefaulting(path: nil)
        )
        viewModel.sourceScanState = .ready(summary)

        let expected = "\(LauncherViewModel.captureDateRangeDayFormatter.string(from: start)) – \(LauncherViewModel.captureDateRangeDayYearFormatter.string(from: end))"
        XCTAssertEqual(viewModel.setupInventoryCaptureDateRangeText, expected)
    }

    func testLauncherSourceScopeSummaryCaptureDateRangeTextFormatsCrossYearRangeWithYearOnBothEnds() {
        let start = makeDate(year: 2025, month: 12, day: 30)
        let end = makeDate(year: 2026, month: 1, day: 2)
        let summary = LauncherSourceScopeSummary(summary: makeDatedScanSummary(dates: [start, end]))

        let viewModel = LauncherViewModel(
            destinationRemembering: StubLauncherDestinationRemembering(initialPath: nil),
            destinationDefaulting: StubLauncherDestinationDefaulting(path: nil)
        )
        viewModel.sourceScanState = .ready(summary)

        let expected = "\(LauncherViewModel.captureDateRangeDayYearFormatter.string(from: start)) – \(LauncherViewModel.captureDateRangeDayYearFormatter.string(from: end))"
        XCTAssertEqual(viewModel.setupInventoryCaptureDateRangeText, expected)
    }

    func testLauncherWindowMetricsKeepAMinimumWidthThatFitsTheIdealWidth() {
        XCTAssertGreaterThan(LauncherWindowMetrics.minWidth, 0)
        XCTAssertLessThanOrEqual(LauncherWindowMetrics.minWidth, LauncherWindowMetrics.idealWidth)
    }

    func testImportPresentationProgressAndRemainingTime() {
        // 50% of files copied in the copy band (0.18 -> 0.52):
        // 0.18 + 0.5 * 0.34 = 0.35.
        let fraction = LauncherImportPresentation.progressFraction(
            phase: .copy,
            totalCount: 100,
            copiedCount: 50,
            verifiedCount: 0,
            committedCount: 0,
            isSuccess: false
        )
        XCTAssertEqual(fraction, 0.35, accuracy: 0.0001)

        let remaining = LauncherImportPresentation.estimatedRemainingText(
            now: Date(timeIntervalSince1970: 30),
            runStartedAt: Date(timeIntervalSince1970: 0),
            phase: .copy,
            copiedCount: 1,
            progressFraction: 0.5
        )
        XCTAssertEqual(remaining, "About 30 seconds remaining")
    }

    func testProgressFractionUsesByteFractionForCopyAndVerifyBandsWhenAvailable() {
        // Copy band: 0.18 -> 0.52 (span 0.34).
        let byteWeightedCopy = LauncherImportPresentation.progressFraction(
            phase: .copy,
            totalCount: 2,
            copiedCount: 1,
            verifiedCount: 0,
            committedCount: 0,
            isSuccess: false,
            copyByteFraction: 0.1
        )
        XCTAssertEqual(byteWeightedCopy, 0.18 + 0.1 * 0.34, accuracy: 0.0001)

        let countWeightedCopy = LauncherImportPresentation.progressFraction(
            phase: .copy,
            totalCount: 2,
            copiedCount: 1,
            verifiedCount: 0,
            committedCount: 0,
            isSuccess: false,
            copyByteFraction: nil
        )
        XCTAssertEqual(countWeightedCopy, 0.18 + 0.5 * 0.34, accuracy: 0.0001)
        XCTAssertLessThan(byteWeightedCopy, countWeightedCopy)

        // Verify band: 0.52 -> 0.86 (span 0.34).
        let byteWeightedVerify = LauncherImportPresentation.progressFraction(
            phase: .verify,
            totalCount: 2,
            copiedCount: 2,
            verifiedCount: 1,
            committedCount: 0,
            isSuccess: false,
            copyByteFraction: 1.0,
            verifyByteFraction: 0.25
        )
        XCTAssertEqual(byteWeightedVerify, 0.52 + 0.25 * 0.34, accuracy: 0.0001)
    }

    func testProgressFractionCopyToVerifyTransitionIsSeamlessAndMonotonic() {
        // End of Copy (copyByteFraction = 1.0) and start of Verify (verifyByteFraction = 0.0)
        // both map to 0.52 so the bar never snaps or moves backward.
        let copyEnd = LauncherImportPresentation.progressFraction(
            phase: .copy, totalCount: 4, copiedCount: 4, verifiedCount: 0,
            committedCount: 0, isSuccess: false, copyByteFraction: 1.0, verifyByteFraction: 0.0
        )
        let verifyStart = LauncherImportPresentation.progressFraction(
            phase: .verify, totalCount: 4, copiedCount: 4, verifiedCount: 0,
            committedCount: 0, isSuccess: false, copyByteFraction: 1.0, verifyByteFraction: 0.0
        )
        let verifyEnd = LauncherImportPresentation.progressFraction(
            phase: .verify, totalCount: 4, copiedCount: 4, verifiedCount: 4,
            committedCount: 0, isSuccess: false, copyByteFraction: 1.0, verifyByteFraction: 1.0
        )
        XCTAssertEqual(copyEnd, 0.52, accuracy: 0.0001)
        XCTAssertEqual(verifyStart, 0.52, accuracy: 0.0001)
        XCTAssertEqual(verifyEnd, 0.86, accuracy: 0.0001)
    }

    func testProgressFractionScanBandIsDeterminateFromScanFraction() {
        let quarter = LauncherImportPresentation.progressFraction(
            phase: .scan, totalCount: 40, copiedCount: 0, verifiedCount: 0,
            committedCount: 0, isSuccess: false, scanFraction: 0.25
        )
        let full = LauncherImportPresentation.progressFraction(
            phase: .scan, totalCount: 40, copiedCount: 0, verifiedCount: 0,
            committedCount: 0, isSuccess: false, scanFraction: 1.0
        )
        XCTAssertEqual(quarter, 0.25 * 0.15, accuracy: 0.0001)
        XCTAssertEqual(full, 0.15, accuracy: 0.0001)
        XCTAssertLessThan(quarter, full)
    }

    func testProgressFractionCommitAdvancesInRealTime() {
        let start = LauncherImportPresentation.progressFraction(
            phase: .commit, totalCount: 10, copiedCount: 10, verifiedCount: 10,
            committedCount: 0, isSuccess: false, copyByteFraction: 1.0, verifyByteFraction: 1.0
        )
        let half = LauncherImportPresentation.progressFraction(
            phase: .commit, totalCount: 10, copiedCount: 10, verifiedCount: 10,
            committedCount: 5, isSuccess: false, copyByteFraction: 1.0, verifyByteFraction: 1.0
        )
        XCTAssertEqual(start, 0.86, accuracy: 0.0001)
        XCTAssertGreaterThan(half, start)
        XCTAssertLessThan(half, 0.98)
    }
}
