import Foundation
import SwiftUI
import XCTest
import FyluroCore
import FyluroEngine
@testable import fyluroLauncher

@MainActor
final class LauncherFailureAndWarningPresentationTests: XCTestCase {
    private func makeIsolatedViewModel() -> LauncherViewModel {
        let suiteName = "fyluro-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        return LauncherViewModel(
            sourceDefaulting: StubLauncherSourceDefaulting(path: nil),
            destinationRemembering: StubLauncherDestinationRemembering(initialPath: nil),
            destinationDefaulting: StubLauncherDestinationDefaulting(path: nil),
            pathSchemeSettingsStore: LauncherPathSchemeSettingsStore(
                pathSchemeRemembering: StubLauncherPathSchemeRemembering(initialConfiguration: .default)
            ),
            transferSettingsStore: LauncherTransferSettingsStore(
                memory: LauncherParallelCopiesMemory(userDefaults: defaults)
            ),
            filmModeRemembering: LauncherFilmModeMemory(userDefaults: defaults),
            workspaceNotificationCenter: NotificationCenter()
        )
    }

    func testEmptySourceKeepsImportDisabledAndNonEmptyEnablesImport() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("fyluro-empty-ready-\(UUID().uuidString)", isDirectory: true)
        let sourceDir = tempRoot.appendingPathComponent("source", isDirectory: true)
        let destDir = tempRoot.appendingPathComponent("dest", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let viewModel = makeIsolatedViewModel()
        viewModel.sourcePath = sourceDir.path
        viewModel.destinationPath = destDir.path
        viewModel.sourceScanTask?.cancel()
        viewModel.destinationSpaceCheckTask?.cancel()
        viewModel.destinationSpaceState = .sufficient(availableBytes: 1_000_000_000)

        viewModel.sourceScanState = .ready(
            LauncherSourceScopeSummary(itemCount: 0, photoCount: 0, videoCount: 0, totalBytes: 0)
        )
        XCTAssertTrue(viewModel.canStart)
        XCTAssertFalse(viewModel.isImportReady)

        viewModel.sourceScanState = .ready(
            LauncherSourceScopeSummary(itemCount: 3, photoCount: 2, videoCount: 1, totalBytes: 12_000)
        )
        XCTAssertTrue(viewModel.isImportReady)
    }

    func testSetupStatusNoticeDeduplicatesUnreadableSourceAndShowsRejectedDropsInReadyState() {
        let viewModel = makeIsolatedViewModel()

        viewModel.runState = .idle
        viewModel.sourceScanState = .failed("Source must be a readable folder.")
        viewModel.statusMessage = "Source must be a readable folder."
        XCTAssertNil(viewModel.setupRouteErrorText)
        XCTAssertNil(viewModel.setupDropNoticeText)
        XCTAssertNil(viewModel.setupStatusNotice)
        XCTAssertNil(viewModel.setupStatusNoticeText)

        viewModel.sourceScanState = .idle
        viewModel.statusMessage = "Destination must be a writable folder."
        XCTAssertEqual(viewModel.setupRouteErrorText, "Destination must be a writable folder.")
        XCTAssertNil(viewModel.setupDropNoticeText)
        XCTAssertEqual(viewModel.setupStatusNotice?.tone, .error)
        XCTAssertEqual(viewModel.setupStatusNotice?.text, "Destination must be a writable folder.")

        let droppedFileURL = FileManager.default.temporaryDirectory.appendingPathComponent("not-a-folder-\(UUID().uuidString).txt")
        FileManager.default.createFile(atPath: droppedFileURL.path, contents: Data())
        defer { try? FileManager.default.removeItem(at: droppedFileURL) }

        // Rejected drop keeps route error visible too when both apply.
        viewModel.acceptDroppedSource([droppedFileURL])
        XCTAssertNotNil(viewModel.setupDropNoticeText)
        XCTAssertEqual(viewModel.setupStatusNotice?.tone, .attention)

        // Rejected drop also surfaces when state is ready.
        viewModel.dropRejectedMessage = nil
        viewModel.runState = .ready
        viewModel.statusMessage = "Import ready"
        viewModel.acceptDroppedSource([droppedFileURL])
        XCTAssertNil(viewModel.setupRouteErrorText)
        XCTAssertNotNil(viewModel.setupDropNoticeText)
        XCTAssertEqual(viewModel.setupStatusNotice?.tone, .attention)
        XCTAssertNotNil(viewModel.setupStatusNotice?.text)
    }

    func testDestinationSpaceWarningSwitchesToneAndTitleOnOverride() {
        let viewModel = makeIsolatedViewModel()
        viewModel.destinationPath = "/Volumes/TINY_DEST"
        viewModel.destinationSpaceCheckTask?.cancel()
        viewModel.sourceScanState = .ready(
            LauncherSourceScopeSummary(itemCount: 1, photoCount: 0, videoCount: 1, totalBytes: 5_000_000)
        )
        viewModel.destinationSpaceState = .insufficient(
            DestinationSpaceChecker.InsufficientSpace(availableBytes: 1_000_000, requiredBytes: 5_250_000),
            overrideAccepted: false
        )

        XCTAssertEqual(viewModel.destinationSpaceWarningTone, .error)
        XCTAssertEqual(viewModel.destinationSpaceWarningTitle, "Not enough free space on TINY_DEST")
        XCTAssertNotNil(viewModel.destinationSpaceWarningText)
        XCTAssertFalse(viewModel.destinationSpaceWarningText?.contains("headroom") ?? true)
        XCTAssertFalse(viewModel.destinationSpaceWarningText?.contains("Import will stop") ?? true)

        viewModel.acceptDestinationSpaceOverride()

        XCTAssertEqual(viewModel.destinationSpaceWarningTone, .attention)
        XCTAssertEqual(viewModel.destinationSpaceWarningTitle, "Low free space on TINY_DEST — importing anyway")
        XCTAssertTrue(viewModel.destinationSpaceWarningText?.contains("Import will stop before copying if new files do not fit.") ?? false)
    }

    func testCompletionWithWarningsUsesWarningTitleAndAccurateOutcome() {
        let viewModel = makeIsolatedViewModel()
        viewModel.runState = .succeeded(idempotentRerun: false)
        viewModel.finalizedCommittedCount = 8
        viewModel.finalizedDuplicateNotCopiedCount = 0
        viewModel.receiptErrors = [
            ReceiptErrorItem(
                eventIndex: 1,
                phase: .scan,
                message: "Permission denied",
                paths: ["DCIM/IMG_0083.DNG", "DCIM/IMG_8248.DNG"]
            ),
        ]

        XCTAssertEqual(viewModel.completionTitle, "Import Completed With Warnings")
        XCTAssertEqual(viewModel.windowSubtitle, "Import Completed With Warnings")
        XCTAssertEqual(viewModel.completionWarningTitle, "2 files could not be imported")
        XCTAssertEqual(
            viewModel.completionOutcomeText,
            "8 files are verified in your library. 2 files could not be imported."
        )
        XCTAssertFalse(viewModel.completionOutcomeText.contains("All "))

        viewModel.finalizedDuplicateNotCopiedCount = 1
        XCTAssertEqual(
            viewModel.completionOutcomeText,
            "8 files are verified in your library. 1 duplicate skipped safely. 2 files could not be imported."
        )

        viewModel.runState = .succeeded(idempotentRerun: true)
        viewModel.finalizedCommittedCount = 0
        viewModel.finalizedDuplicateNotCopiedCount = 5
        XCTAssertEqual(
            viewModel.completionOutcomeText,
            "No new files added. 5 files already exist in your library. 2 files could not be imported."
        )
    }

    func testStoppedRouteStatusUsesStopIconAndSecondaryColor() {
        XCTAssertEqual(LauncherRouteStatus.stopped.markSymbol, "stop.circle.fill")
        XCTAssertEqual(LauncherRouteStatus.stopped.markColor, .secondary)
        XCTAssertEqual(LauncherRouteStatus.failed.markColor, LauncherTone.error.color)
    }

    func testFailureAndStoppedMessagesReflectSafetyAndEvidence() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("fyluro-evidence-\(UUID().uuidString)", isDirectory: true)
        let stagingDir = tempRoot.appendingPathComponent("staging", isDirectory: true)
        let receiptFile = tempRoot.appendingPathComponent("receipt.jsonl")
        try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: receiptFile.path, contents: Data())
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let viewModel = makeIsolatedViewModel()

        // Stopped with 0 committed files
        viewModel.runState = .failed(stoppedByUser: true)
        viewModel.failureReason = "cancelled"
        viewModel.finalizedCommittedCount = 0
        XCTAssertEqual(
            viewModel.failureMessage,
            "No files were added to your library. Your source card was not changed."
        )
        XCTAssertNil(viewModel.failureSafetyNoteText)

        // Stopped with raw engine cancellation message and 0 committed files
        viewModel.failureReason = "Failed during copy for G0031814.JPG: Ingest cancelled during copy"
        viewModel.finalizedCommittedCount = 0
        XCTAssertEqual(
            viewModel.failureMessage,
            "No files were added to your library. Your source card was not changed."
        )

        // Stopped with 1 committed file
        viewModel.failureReason = "Import stopped by user."
        viewModel.finalizedCommittedCount = 1
        XCTAssertEqual(
            viewModel.failureMessage,
            "1 verified file was added to your library before stopping. Your source card was not changed."
        )

        // Stopped with N committed files
        viewModel.failureReason = ""
        viewModel.finalizedCommittedCount = 4
        XCTAssertEqual(
            viewModel.failureMessage,
            "4 verified files were added to your library before stopping. Your source card was not changed."
        )

        // Failed run with 0 committed files
        viewModel.runState = .failed(stoppedByUser: false)
        viewModel.failureReason = "No space left on device"
        viewModel.finalizedCommittedCount = 0
        XCTAssertEqual(viewModel.failureMessage, "No space left on device")
        XCTAssertEqual(viewModel.failureSafetyNoteText, "Your source card and library were not changed.")

        // Failed run with partial commit
        viewModel.finalizedCommittedCount = 2
        XCTAssertEqual(
            viewModel.failureSafetyNoteText,
            "Your source card was not changed. 2 verified files were already added to your library."
        )

        // Evidence combinations
        XCTAssertNil(viewModel.failureEvidenceText)

        viewModel.receiptPath = receiptFile.path
        XCTAssertEqual(viewModel.failureEvidenceText, "Receipt saved")

        viewModel.stagingPath = stagingDir.path
        XCTAssertEqual(viewModel.failureEvidenceText, "Receipt and staging files saved")

        viewModel.receiptPath = ""
        XCTAssertEqual(viewModel.failureEvidenceText, "Staging files saved for inspection")
    }

    func testReturnToSetupResetsRunStateWhilePreservingPathsAndFilmMode() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("fyluro-return-setup-\(UUID().uuidString)", isDirectory: true)
        let sourceDir = tempRoot.appendingPathComponent("source", isDirectory: true)
        let destDir = tempRoot.appendingPathComponent("dest", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let viewModel = makeIsolatedViewModel()
        viewModel.sourcePath = sourceDir.path
        viewModel.destinationPath = destDir.path
        viewModel.sourceScanTask?.cancel()
        viewModel.destinationSpaceCheckTask?.cancel()

        let filmOverride = FilmModeOverride(
            year: 2026,
            month: 10,
            camera: "Leica M6",
            filmStock: "Portra 400",
            iso: 400,
            creator: nil,
            copyright: nil
        )
        viewModel.filmModeState = .enabled(filmOverride)
        viewModel.runState = .failed(stoppedByUser: false)
        viewModel.failureReason = "Disk full"
        viewModel.receiptPath = "/tmp/fake-receipt.jsonl"
        viewModel.stagingPath = "/tmp/fake-staging"
        viewModel.dropRejectedMessage = "Drop failed"
        viewModel.receiptErrors = [
            ReceiptErrorItem(eventIndex: 1, phase: .copy, message: "Disk full", paths: ["IMG_0001.JPG"]),
        ]

        viewModel.returnToSetup()

        XCTAssertEqual(viewModel.sourcePath, sourceDir.path)
        XCTAssertEqual(viewModel.destinationPath, destDir.path)
        XCTAssertEqual(viewModel.filmModeState, .enabled(filmOverride))
        XCTAssertEqual(viewModel.uiState, .ready)
        XCTAssertEqual(viewModel.failureReason, "")
        XCTAssertEqual(viewModel.receiptPath, "")
        XCTAssertEqual(viewModel.stagingPath, "")
        XCTAssertTrue(viewModel.receiptErrors.isEmpty)
        XCTAssertNil(viewModel.dropRejectedMessage)
    }
}
