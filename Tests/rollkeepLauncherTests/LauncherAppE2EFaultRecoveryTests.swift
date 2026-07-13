import Foundation
import XCTest
@testable import RollKeepCore
@testable import rollkeepLauncher

extension LauncherAppE2ETests {
    func testAppE2EFaultInjectionScenariosAndFailurePostRunActions() throws {
        let tempRoot = try makeTempDirectory(prefix: "rollkeep-launcher-app-e2e-faults-")
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let source = repoRoot.appendingPathComponent("Tests/TestingDirs/SD_CARD1", isDirectory: true)

        let copyFailure = try runLauncherImport(
            source: source,
            destination: tempRoot.appendingPathComponent("copy-fail", isDirectory: true),
            label: "E2E-015-copy",
            environmentOverrides: [
                "ROLLKEEP_TEST_FAIL_COPY_ON_NTH_FILE": "2",
                "ROLLKEEP_TEST_FAIL_COPY_ERROR_MESSAGE": "Simulated destination disconnect during copy",
            ]
        )
        XCTAssertEqual(copyFailure.viewModel.uiState, .failure)
        XCTAssertTrue(copyFailure.viewModel.failureReason.contains("disconnect"), "Expected disconnect failure reason")
        assertErrorPhaseExists(copyFailure.receiptEvents, expectedPhase: "copy", label: "E2E-015-copy")
        copyFailure.viewModel.openDestination()
        copyFailure.viewModel.openReceipt()
        XCTAssertGreaterThanOrEqual(copyFailure.finder.revealedURLs.count, 2)

        let commitFailure = try runLauncherImport(
            source: source,
            destination: tempRoot.appendingPathComponent("commit-fail", isDirectory: true),
            label: "E2E-015-commit",
            environmentOverrides: [
                "ROLLKEEP_TEST_FAIL_COMMIT_ON_NTH_FILE": "1",
                "ROLLKEEP_TEST_FAIL_COMMIT_ERROR_MESSAGE": "Simulated destination disconnect during commit",
            ]
        )
        XCTAssertEqual(commitFailure.viewModel.uiState, .failure)
        assertErrorPhaseExists(commitFailure.receiptEvents, expectedPhase: "commit", label: "E2E-015-commit")
        XCTAssertTrue(eventTypes(in: commitFailure.receiptEvents).contains("FILE_COMMIT_STARTED"))

        let diskFullFailure = try runLauncherImport(
            source: source,
            destination: tempRoot.appendingPathComponent("disk-full-fail", isDirectory: true),
            label: "E2E-016",
            environmentOverrides: [
                "ROLLKEEP_TEST_FAIL_COPY_ON_NTH_FILE": "2",
                "ROLLKEEP_TEST_FAIL_COPY_ERROR_MESSAGE": "No space left on device (simulated ENOSPC)",
            ]
        )
        XCTAssertEqual(diskFullFailure.viewModel.uiState, .failure)
        XCTAssertTrue(diskFullFailure.viewModel.failureReason.contains("No space left on device"))
        assertErrorPhaseExists(diskFullFailure.receiptEvents, expectedPhase: "copy", label: "E2E-016")

        let preflightSpaceFailure = try runLauncherImport(
            source: source,
            destination: tempRoot.appendingPathComponent("preflight-space-fail", isDirectory: true),
            label: "E2E-034",
            environmentOverrides: [
                "ROLLKEEP_TEST_FORCE_INSUFFICIENT_DISK_SPACE": "1",
            ]
        )
        XCTAssertEqual(preflightSpaceFailure.viewModel.uiState, .failure)
        XCTAssertTrue(preflightSpaceFailure.viewModel.failureReason.contains("insufficient free space"))
        assertErrorPhaseExists(preflightSpaceFailure.receiptEvents, expectedPhase: "copy", label: "E2E-034")
        XCTAssertFalse(
            eventTypes(in: preflightSpaceFailure.receiptEvents).contains("FILE_COPY_STARTED"),
            "E2E-034 should abort before any copy work begins"
        )

        let receiptFailover = try runLauncherImport(
            source: source,
            destination: tempRoot.appendingPathComponent("receipt-failover", isDirectory: true),
            label: "E2E-017",
            environmentOverrides: [
                "ROLLKEEP_TEST_RECEIPT_FAIL_DEST_APPEND_AT_EVENT_INDEX": "3",
            ]
        )
        XCTAssertEqual(receiptFailover.viewModel.uiState, .success)
        let transitions = arrayValue(receiptFailover.summaryData["receipt_sink_transitions"])
        let receiptPaths = arrayValue(receiptFailover.summaryData["receipt_paths"])
        XCTAssertGreaterThanOrEqual(transitions.count, 1, "E2E-017 should record sink transition")
        XCTAssertGreaterThanOrEqual(receiptPaths.count, 2, "E2E-017 should include destination and fallback receipt paths")

        let verifyFailure = try runLauncherImport(
            source: source,
            destination: tempRoot.appendingPathComponent("verify-fail", isDirectory: true),
            label: "E2E-018",
            environmentOverrides: [
                "ROLLKEEP_TEST_CORRUPT_STAGING_BEFORE_VERIFY": "1",
            ]
        )
        XCTAssertEqual(verifyFailure.viewModel.uiState, .failure)
        assertErrorPhaseExists(verifyFailure.receiptEvents, expectedPhase: "verify", label: "E2E-018")
        XCTAssertFalse(eventTypes(in: verifyFailure.receiptEvents).contains("FILE_COMMIT_STARTED"), "E2E-018 should stop before commit")
    }

    func testAppE2ECrashRestartRecoveryAndStopFlow() throws {
        let tempRoot = try makeTempDirectory(prefix: "rollkeep-launcher-app-e2e-recovery-")
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let source = repoRoot.appendingPathComponent("Tests/TestingDirs/SD_CARD1", isDirectory: true)
        let destination = tempRoot.appendingPathComponent("recovery-dest", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        let recoveryViewModel = makeViewModel(cliEnvironmentOverrides: [
            "ROLLKEEP_TEST_SLEEP_BEFORE_COMMIT_SECONDS": "30",
        ])
        recoveryViewModel.sourcePath = source.path
        recoveryViewModel.destinationPath = destination.path
        XCTAssertTrue(waitUntil(timeout: 60) { recoveryViewModel.isImportReady })

        recoveryViewModel.startIngest()

        XCTAssertTrue(waitUntil(timeout: 120) {
            guard let receiptPath = activeReceiptPath(viewModel: recoveryViewModel, destination: destination) else {
                return false
            }
            guard let text = try? String(contentsOfFile: receiptPath, encoding: .utf8) else {
                return false
            }
            return text.contains("\"event_type\":\"FILE_VERIFIED\"") && !text.contains("\"event_type\":\"FILE_COMMIT_STARTED\"")
        }, "Timed out waiting for pre-commit verified state before stop")

        recoveryViewModel.stopIngest()

        XCTAssertTrue(waitUntil(timeout: 120) {
            recoveryViewModel.uiState == .failure && !recoveryViewModel.isRunning
        }, "Stop flow did not finish")
        XCTAssertTrue(recoveryViewModel.wasStoppedByUser)
        XCTAssertEqual(recoveryViewModel.failureTitle, "Import Stopped")

        let stopReceiptPath = resolveReceiptPath(viewModel: recoveryViewModel, destination: destination)
        guard let stopReceiptPath else {
            XCTFail("Stop flow should expose a receipt path")
            return
        }
        let stopEvents = try loadReceiptEvents(path: stopReceiptPath)
        let retainedStagingPath = inferRetainedStagingSessionPath(events: stopEvents, destination: destination)
        XCTAssertNotNil(retainedStagingPath, "Stop flow should retain a staging session path")
        if let retainedStagingPath {
            var isDirectory: ObjCBool = false
            XCTAssertTrue(FileManager.default.fileExists(atPath: retainedStagingPath, isDirectory: &isDirectory))
            XCTAssertTrue(isDirectory.boolValue)
            let retainedFiles = FileManager.default.enumerator(atPath: retainedStagingPath)?
                .allObjects
                .compactMap { $0 as? String }
                .filter { !$0.hasSuffix("/") }
            XCTAssertGreaterThanOrEqual(retainedFiles?.count ?? 0, 1, "Retained staging should include copied files")
        }

        let recoveryRun = try runLauncherImport(
            source: source,
            destination: destination,
            label: "E2E-022-recovery"
        )
        XCTAssertEqual(recoveryRun.viewModel.uiState, .success)
        XCTAssertGreaterThan(intValue(totalsByOutcome(from: recoveryRun.summaryData)["committed"]), 0, "Recovery run should commit files")

        let rerun = try runLauncherImport(
            source: source,
            destination: destination,
            label: "E2E-022-rerun"
        )
        XCTAssertEqual(rerun.viewModel.uiState, .success)
        XCTAssertTrue(rerun.viewModel.isIdempotentRerun)
        let totals = totalsByOutcome(from: rerun.summaryData)
        XCTAssertEqual(intValue(totals["committed"]), 0)
        XCTAssertGreaterThan(intValue(totals["duplicate_not_copied"]), 0)
    }
}
