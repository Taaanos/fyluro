import Foundation
import XCTest
@testable import fyluroLauncher

@MainActor
final class LauncherWindowSubtitleTests: XCTestCase {
    func testWindowSubtitleTracksUIStateAndClearsOnSetup() {
        let viewModel = LauncherViewModel(workspaceNotificationCenter: NotificationCenter())

        viewModel.runState = .idle
        XCTAssertEqual(viewModel.windowSubtitle, "")

        viewModel.runState = .ready
        XCTAssertEqual(viewModel.windowSubtitle, "")

        viewModel.runState = .running(stopRequested: false)
        XCTAssertEqual(viewModel.windowSubtitle, "Importing items…")

        viewModel.scannedCandidateCount = 1
        XCTAssertEqual(viewModel.windowSubtitle, "Importing 1 item…")

        viewModel.scannedCandidateCount = 111
        XCTAssertEqual(viewModel.windowSubtitle, "Importing 111 items…")

        viewModel.runState = .succeeded(idempotentRerun: false)
        XCTAssertEqual(viewModel.windowSubtitle, "Import Complete")

        viewModel.runState = .failed(stoppedByUser: true)
        XCTAssertEqual(viewModel.windowSubtitle, "Import Stopped")

        viewModel.runState = .failed(stoppedByUser: false)
        XCTAssertEqual(viewModel.windowSubtitle, "Import Needs Attention")
    }

    func testCompletionTitleAndOutcomeCoverAllCompletionCases() {
        let viewModel = LauncherViewModel(workspaceNotificationCenter: NotificationCenter())
        viewModel.runState = .succeeded(idempotentRerun: false)
        XCTAssertEqual(viewModel.completionTitle, "Import Complete")

        viewModel.finalizedCommittedCount = 0
        viewModel.finalizedDuplicateNotCopiedCount = 0
        XCTAssertEqual(viewModel.completionOutcomeText, "No new files added to your library.")

        viewModel.finalizedCommittedCount = 1
        XCTAssertEqual(viewModel.completionOutcomeText, "1 file is verified in your library.")

        viewModel.finalizedCommittedCount = 111
        XCTAssertEqual(viewModel.completionOutcomeText, "All 111 files are verified in your library.")

        viewModel.finalizedCommittedCount = 10
        viewModel.finalizedDuplicateNotCopiedCount = 1
        XCTAssertEqual(
            viewModel.completionOutcomeText,
            "10 files are verified in your library. 1 duplicate skipped safely."
        )

        viewModel.finalizedCommittedCount = 1
        viewModel.finalizedDuplicateNotCopiedCount = 2
        XCTAssertEqual(
            viewModel.completionOutcomeText,
            "1 file is verified in your library. 2 duplicates skipped safely."
        )

        viewModel.runState = .succeeded(idempotentRerun: true)
        viewModel.finalizedCommittedCount = 0
        viewModel.finalizedDuplicateNotCopiedCount = 1
        XCTAssertEqual(
            viewModel.completionOutcomeText,
            "No new files added. 1 file already exists in your library."
        )

        viewModel.finalizedDuplicateNotCopiedCount = 5
        XCTAssertEqual(
            viewModel.completionOutcomeText,
            "No new files added. All 5 files already exist in your library."
        )
    }

    func testBodySummaryTitlesDifferFromWindowSubtitles() {
        let viewModel = LauncherViewModel(workspaceNotificationCenter: NotificationCenter())

        viewModel.runState = .running(stopRequested: false)
        viewModel.latestCorePhase = .scan
        viewModel.scannedCandidateCount = 111
        XCTAssertEqual(viewModel.windowSubtitle, "Importing 111 items…")
        XCTAssertEqual(viewModel.importingBodyTitle, "Scanning source media…")
        XCTAssertNotEqual(viewModel.importingBodyTitle, viewModel.windowSubtitle)

        viewModel.latestCorePhase = .copy
        viewModel.copiedCount = 72
        XCTAssertEqual(viewModel.importingBodyTitle, "72 of 111 items copied")
        XCTAssertNotEqual(viewModel.importingBodyTitle, viewModel.windowSubtitle)

        viewModel.latestCorePhase = .verify
        viewModel.verifiedCount = 50
        XCTAssertEqual(viewModel.importingBodyTitle, "50 of 111 items verified")
        XCTAssertNotEqual(viewModel.importingBodyTitle, viewModel.windowSubtitle)

        viewModel.runState = .succeeded(idempotentRerun: false)
        viewModel.finalizedCommittedCount = 0
        XCTAssertEqual(viewModel.windowSubtitle, "Import Complete")
        XCTAssertEqual(viewModel.completionSummaryTitle, "No new items imported")
        XCTAssertNotEqual(viewModel.completionSummaryTitle, viewModel.windowSubtitle)

        viewModel.finalizedCommittedCount = 1
        XCTAssertEqual(viewModel.completionSummaryTitle, "1 item imported")
        XCTAssertNotEqual(viewModel.completionSummaryTitle, viewModel.windowSubtitle)

        viewModel.finalizedCommittedCount = 111
        XCTAssertEqual(viewModel.completionSummaryTitle, "111 items imported")
        XCTAssertNotEqual(viewModel.completionSummaryTitle, viewModel.windowSubtitle)

        viewModel.runState = .succeeded(idempotentRerun: true)
        XCTAssertEqual(viewModel.completionSummaryTitle, "Already in Library")
        XCTAssertNotEqual(viewModel.completionSummaryTitle, viewModel.windowSubtitle)

        viewModel.runState = .failed(stoppedByUser: true)
        XCTAssertEqual(viewModel.windowSubtitle, "Import Stopped")
        XCTAssertEqual(viewModel.failureSummaryTitle, "Transfer stopped by user")
        XCTAssertNotEqual(viewModel.failureSummaryTitle, viewModel.windowSubtitle)

        viewModel.runState = .failed(stoppedByUser: false)
        XCTAssertEqual(viewModel.windowSubtitle, "Import Needs Attention")
        XCTAssertEqual(viewModel.failureSummaryTitle, "Transfer failed")
        XCTAssertNotEqual(viewModel.failureSummaryTitle, viewModel.windowSubtitle)
    }

    func testCompletionStatRowsGroupTransferAndMediaMetricsAcrossBalancedRows() {
        let viewModel = LauncherViewModel(workspaceNotificationCenter: NotificationCenter())
        viewModel.finalizedCommittedCount = 111
        viewModel.finalizedDuplicateNotCopiedCount = 0
        viewModel.scannedTotalBytes = 8_050_000_000
        viewModel.finalizedTotalDurationMs = 146_000

        let singleRow = viewModel.completionStatRows
        XCTAssertEqual(singleRow.count, 1)
        XCTAssertEqual(singleRow[0].map(\.title), ["Added to library", "Already in library", "Size", "Elapsed"])

        viewModel.finalizedPhotoCount = 89
        viewModel.finalizedVideoCount = 11
        viewModel.finalizedAudioCount = 2
        viewModel.finalizedConflictsRenamedCount = 3
        viewModel.lastPreviewSummary = LauncherSourceScopeSummary(
            itemCount: 102,
            photoCount: 89,
            videoCount: 11,
            audioCount: 2,
            totalBytes: 8_050_000_000,
            cameraEntries: [LauncherSourceCameraSummary(label: "ilce-7cm2", fileCount: 100)]
        )

        let twoRows = viewModel.completionStatRows
        XCTAssertEqual(twoRows.count, 2)
        XCTAssertEqual(twoRows[0].map(\.title), ["Added to library", "Already in library", "Size", "Elapsed"])
        XCTAssertEqual(twoRows[1].map(\.title), ["Photos", "Videos", "Audio", "Cameras", "Renamed"])
    }
}
