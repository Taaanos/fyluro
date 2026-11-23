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
}
