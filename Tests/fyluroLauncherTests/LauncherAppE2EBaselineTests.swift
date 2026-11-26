import Foundation
import XCTest
@testable import FyluroCore
@testable import fyluroLauncher

extension LauncherAppE2ETests {
    func testAppE2EBaselineRerunImmutabilityTimestampsAndWriteAudit() throws {
        let tempRoot = try makeTempDirectory(prefix: "fyluro-launcher-app-e2e-baseline-")
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        for fixture in FixtureSource.all {
            let source = repoRoot.appendingPathComponent(fixture.relativePath, isDirectory: true)
            XCTAssertTrue(FileManager.default.fileExists(atPath: source.path), "Missing fixture \(fixture.label)")

            let sourceBefore = try fileManifest(root: source)
            let destination = tempRoot.appendingPathComponent("\(fixture.label)-dest", isDirectory: true)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

            let firstRun = try runLauncherImport(
                source: source,
                destination: destination,
                label: "\(fixture.label)-first-pass"
            )

            XCTAssertEqual(firstRun.viewModel.uiState, .success)
            XCTAssertFalse(firstRun.viewModel.receiptPath.isEmpty)
            assertReceiptLifecycle(firstRun.receiptEvents, label: "\(fixture.label)-first-pass")
            assertDestinationConstrainedWrites(summaryData: firstRun.summaryData, destination: destination, label: "\(fixture.label)-first-pass")
            try assertCommittedFileMtimePreservation(summaryData: firstRun.summaryData, label: "\(fixture.label)-first-pass")

            let rerun = try runLauncherImport(
                source: source,
                destination: destination,
                label: "\(fixture.label)-rerun"
            )

            XCTAssertEqual(rerun.viewModel.uiState, .success)
            XCTAssertTrue(rerun.viewModel.isIdempotentRerun, "\(fixture.label)-rerun should report idempotent rerun")
            let rerunTotals = totalsByOutcome(from: rerun.summaryData)
            XCTAssertEqual(intValue(rerunTotals["committed"]), 0, "\(fixture.label)-rerun should commit 0 files")
            XCTAssertGreaterThan(intValue(rerunTotals["duplicate_not_copied"]), 0, "\(fixture.label)-rerun should report duplicates")

            let sourceAfter = try fileManifest(root: source)
            XCTAssertEqual(sourceBefore, sourceAfter, "\(fixture.label) source fixture mutated")
        }
    }

    func testAppE2ERejectsOverlappingPathsBeforeStart() throws {
        let tempRoot = try makeTempDirectory(prefix: "fyluro-launcher-app-e2e-overlap-")
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let source = tempRoot.appendingPathComponent("source", isDirectory: true)
        let sourceDCIM = source.appendingPathComponent("DCIM", isDirectory: true)
        let nestedDestination = source.appendingPathComponent("dest", isDirectory: true)
        let siblingDestination = tempRoot.appendingPathComponent("dest", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDCIM, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: nestedDestination, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: siblingDestination, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: repoRoot.appendingPathComponent("Tests/TestingDirs/SD_CARD1/DCIM/IMG_8236.HEIC"),
            to: sourceDCIM.appendingPathComponent("IMG_8236.HEIC")
        )

        let viewModel = makeViewModel(cliEnvironmentOverrides: [:])
        viewModel.sourcePath = source.path
        viewModel.destinationPath = source.path

        XCTAssertFalse(viewModel.canStart)
        XCTAssertEqual(viewModel.statusMessage, "Source and destination must be different folders, and neither can be inside the other.")

        viewModel.destinationPath = nestedDestination.path
        XCTAssertFalse(viewModel.canStart)
        XCTAssertEqual(viewModel.statusMessage, "Source and destination must be different folders, and neither can be inside the other.")

        viewModel.destinationPath = siblingDestination.path
        XCTAssertTrue(waitUntil(timeout: 60) { viewModel.isImportReady })
        XCTAssertTrue(viewModel.canStart)
    }
}
