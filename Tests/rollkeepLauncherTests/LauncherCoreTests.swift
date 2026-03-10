import Foundation
import XCTest
@testable import RollKeepCore
@testable import rollkeepLauncher

final class LauncherCoreTests: XCTestCase {
    func testSourceAndDestinationValidation() throws {
        let fileManager = FileManager.default
        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("rollkeep-launcher-tests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempRoot) }

        let source = tempRoot.appendingPathComponent("source", isDirectory: true)
        let destination = tempRoot.appendingPathComponent("dest", isDirectory: true)
        let filePath = tempRoot.appendingPathComponent("file.txt", isDirectory: false)

        try fileManager.createDirectory(at: source, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        fileManager.createFile(atPath: filePath.path, contents: Data("x".utf8))

        XCTAssertTrue(LauncherPathValidation.isValidSourcePath(source.path))
        XCTAssertFalse(LauncherPathValidation.isValidSourcePath(filePath.path))

        XCTAssertTrue(LauncherPathValidation.isValidDestinationPath(destination.path))
        XCTAssertFalse(LauncherPathValidation.isValidDestinationPath(filePath.path))
        XCTAssertFalse(LauncherPathValidation.isValidDestinationPath(tempRoot.appendingPathComponent("missing").path))
    }

    func testOutputParserReadsPhasesReceiptAndOutcome() {
        var parser = CLIOutputParser()

        let logUpdate = parser.parse(line: "{\"message\":\"command_started\",\"receipt_path\":\"/tmp/run.ndjson\"}")
        XCTAssertEqual(logUpdate.phase, .scan)
        XCTAssertEqual(logUpdate.receiptPath, "/tmp/run.ndjson")

        let verifyUpdate = parser.parse(line: "{\"message\":\"copy_stage_completed\"}")
        XCTAssertEqual(verifyUpdate.phase, .verify)

        let commitUpdate = parser.parse(line: "{\"message\":\"commit_stage_completed\"}")
        XCTAssertEqual(commitUpdate.phase, .commit)

        let summaryUpdate = parser.parse(line: "Status: VERIFIED")
        XCTAssertEqual(summaryUpdate.phase, .finished)
        XCTAssertEqual(summaryUpdate.result, .success)

        let idempotentUpdate = parser.parse(line: "Idempotency: idempotent_rerun (new_files_committed: 0, duplicates_skipped: 9)")
        XCTAssertEqual(idempotentUpdate.idempotentRerun, true)

        let failurePhase = parser.parse(line: "- phase: verify")
        XCTAssertEqual(failurePhase.phase, .verify)

        let failureReason = parser.parse(line: "- reason: hash mismatch")
        XCTAssertEqual(failureReason.failureReason, "hash mismatch")

        let failureStaging = parser.parse(line: "- staging: /tmp/staging/session-1")
        XCTAssertEqual(failureStaging.stagingPath, "/tmp/staging/session-1")

        let failureStatus = parser.parse(line: "Status: FAILED")
        XCTAssertEqual(failureStatus.result, .failure)
    }

    func testReceiptEventParserTracksProgressAndErrors() {
        var parser = ReceiptEventParser()

        let scan = parser.parse(line: """
        {"event_index":2,"event_type":"SCAN_SUMMARY","phase":"scan","data":{"candidate_count":245}}
        """)
        XCTAssertEqual(scan.phase, .scan)
        XCTAssertEqual(scan.scannedCandidateCount, 245)

        let planUpdate = parser.parse(line: """
        {"event_index":4,"event_type":"PLAN_COMPUTED","phase":"plan","data":{"files":[{"outcome":"stage_and_commit"},{"outcome":"duplicate_not_copied"},{"outcome":"stage_and_commit"}]}}
        """)
        XCTAssertEqual(planUpdate.phase, .plan)
        XCTAssertEqual(planUpdate.plannedStageAndCommit, 2)
        XCTAssertEqual(planUpdate.duplicateNotCopied, 1)

        let copyStarted = parser.parse(line: """
        {"event_index":5,"event_type":"FILE_COPY_STARTED","phase":"copy","data":{"status":"started","executed":true}}
        """)
        XCTAssertEqual(copyStarted.copiedIncrement, 1)

        let queuedCopy = parser.parse(line: """
        {"event_index":5,"event_type":"FILE_COPY_STARTED","phase":"copy","data":{"status":"queued","executed":true}}
        """)
        XCTAssertEqual(queuedCopy.copiedIncrement, 0)

        let verified = parser.parse(line: """
        {"event_index":6,"event_type":"FILE_VERIFIED","phase":"verify","data":{"outcome":"verified","executed":true}}
        """)
        XCTAssertEqual(verified.verifiedIncrement, 1)

        let committed = parser.parse(line: """
        {"event_index":7,"event_type":"FILE_COMMITTED","phase":"commit","data":{"status":"committed","executed":true}}
        """)
        XCTAssertEqual(committed.committedIncrement, 1)

        let error = parser.parse(line: """
        {"event_index":8,"event_type":"ERROR","phase":"commit","data":{"error":"Disk full","staging_path":"/dest/_ingest_staging/sid/file.mov","final_path":"/dest/2026/022026/cam/Videos/file.mov"}}
        """)
        XCTAssertEqual(error.errorItem?.eventIndex, 8)
        XCTAssertEqual(error.errorItem?.phase, .commit)
        XCTAssertEqual(error.errorItem?.message, "Disk full")
        XCTAssertEqual(error.errorItem?.paths, [
            "/dest/_ingest_staging/sid/file.mov",
            "/dest/2026/022026/cam/Videos/file.mov",
        ])
    }

    func testReceiptEventParserSupportsPlanCountFallbackFields() {
        var parser = ReceiptEventParser()

        let update = parser.parse(line: """
        {"event_index":9,"event_type":"PLAN_COMPUTED","phase":"plan","data":{"planned_file_count":11,"duplicate_not_copied_count":3}}
        """)

        XCTAssertEqual(update.plannedStageAndCommit, 11)
        XCTAssertEqual(update.duplicateNotCopied, 3)
    }

    func testReceiptEventParserReadsScanMediaCountsAndBytes() {
        var parser = ReceiptEventParser()

        let scan = parser.parse(line: """
        {"event_index":2,"event_type":"SCAN_SUMMARY","phase":"scan","data":{"candidate_count":4,"photos":{"count":3,"bytes":1500},"videos":{"count":1,"bytes":2700}}}
        """)

        XCTAssertEqual(scan.scannedCandidateCount, 4)
        XCTAssertEqual(scan.scanPhotoCount, 3)
        XCTAssertEqual(scan.scanVideoCount, 1)
        XCTAssertEqual(scan.scanPhotoBytes, 1500)
        XCTAssertEqual(scan.scanVideoBytes, 2700)
    }

    func testReceiptEventParserReadsFinalOutcomeTotalsFromSummary() {
        var parser = ReceiptEventParser()

        let summary = parser.parse(line: """
        {"event_index":55,"event_type":"SUMMARY","phase":"finalize","data":{"status":"completed","dry_run":false,"totals_by_outcome":{"committed":0,"duplicate_not_copied":9}}}
        """)

        XCTAssertEqual(summary.finalizedCommittedCount, 0)
        XCTAssertEqual(summary.finalizedDuplicateNotCopiedCount, 9)
        XCTAssertEqual(summary.finalizedIdempotentRerun, true)
    }

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

    func testReceiptEventParserExtractsTouchedPaths() {
        var parser = ReceiptEventParser()

        let summary = parser.parse(line: """
        {"event_index":25,"event_type":"SUMMARY","phase":"finalize","data":{"touched_paths":{"created_directories":["/dest/2026/022026/cam/Photos"],"written_staging_files":["/dest/_ingest_staging/sid/a.jpg"],"move_operations":[{"from":"/dest/_ingest_staging/sid/a.jpg","to":"/dest/2026/022026/cam/Photos/a.jpg"}]}}}
        """)

        XCTAssertEqual(summary.phase, .finalize)
        XCTAssertEqual(summary.touchedPaths?.sorted(), [
            "/dest/2026/022026/cam/Photos",
            "/dest/_ingest_staging/sid/a.jpg",
            "/dest/2026/022026/cam/Photos/a.jpg",
        ].sorted())
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

    func testLauncherWindowMetricsKeepSetupStateTallEnoughForScanResults() {
        XCTAssertEqual(LauncherWindowMetrics.preferredContentHeight(for: .idle), LauncherWindowMetrics.setupHeight)
        XCTAssertEqual(LauncherWindowMetrics.preferredContentHeight(for: .ready), LauncherWindowMetrics.setupHeight)
        XCTAssertEqual(LauncherWindowMetrics.preferredContentHeight(for: .running), LauncherWindowMetrics.compactHeight)
        XCTAssertGreaterThan(LauncherWindowMetrics.setupHeight, LauncherWindowMetrics.compactHeight)
    }

    func testVolumeInspectorRanksLikelyCardsByDCIMThenRemovableHint() throws {
        let fileManager = FileManager.default
        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("rollkeep-launcher-volumes-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempRoot) }

        let archive = tempRoot.appendingPathComponent("ARCHIVE", isDirectory: true)
        let camera = tempRoot.appendingPathComponent("CAMERA_CARD", isDirectory: true)
        let removable = tempRoot.appendingPathComponent("USB_MEDIA", isDirectory: true)

        try fileManager.createDirectory(at: archive, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: camera.appendingPathComponent("DCIM", isDirectory: true), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: removable, withIntermediateDirectories: true)

        let removablePaths = Set([removable.path])
        let inspector = LauncherVolumeInspector(
            volumesRoot: tempRoot,
            fileManager: fileManager,
            removableHintProvider: { removablePaths.contains($0.standardizedFileURL.path) }
        )

        XCTAssertEqual(inspector.likelyCardVolumes().map(\.path), [
            camera.path,
            removable.path,
        ])
    }

    func testSourceAutoPickerUsesHighestRankedLikelyCard() throws {
        let fileManager = FileManager.default
        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("rollkeep-launcher-autopick-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempRoot) }

        let preferred = tempRoot.appendingPathComponent("CARD_A", isDirectory: true)
        let fallback = tempRoot.appendingPathComponent("CARD_B", isDirectory: true)

        try fileManager.createDirectory(at: preferred.appendingPathComponent("DCIM", isDirectory: true), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: fallback, withIntermediateDirectories: true)

        let removablePaths = Set([fallback.path])
        let picker = LauncherSourceAutoPicker(
            inspector: LauncherVolumeInspector(
                volumesRoot: tempRoot,
                fileManager: fileManager,
                removableHintProvider: { removablePaths.contains($0.standardizedFileURL.path) }
            )
        )

        XCTAssertEqual(picker.suggestedSourcePath(), preferred.path)
    }

    func testDestinationAutoPickerUsesMostRecentReceiptsDirectory() throws {
        let fileManager = FileManager.default
        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("rollkeep-launcher-destination-autopick-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempRoot) }

        let older = tempRoot.appendingPathComponent("ARCHIVE_A", isDirectory: true)
        let newer = tempRoot.appendingPathComponent("ARCHIVE_B", isDirectory: true)
        try fileManager.createDirectory(at: older.appendingPathComponent("_ingest_receipts", isDirectory: true), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: newer.appendingPathComponent("_ingest_receipts", isDirectory: true), withIntermediateDirectories: true)

        let olderDate = Date(timeIntervalSince1970: 1_700_000_000)
        let newerDate = Date(timeIntervalSince1970: 1_700_100_000)
        try fileManager.setAttributes(
            [.modificationDate: olderDate],
            ofItemAtPath: older.appendingPathComponent("_ingest_receipts", isDirectory: true).path
        )
        try fileManager.setAttributes(
            [.modificationDate: newerDate],
            ofItemAtPath: newer.appendingPathComponent("_ingest_receipts", isDirectory: true).path
        )

        let picker = LauncherReceiptBasedDestinationDefault(
            inspector: LauncherVolumeInspector(
                volumesRoot: tempRoot,
                fileManager: fileManager,
                removableHintProvider: { _ in false }
            ),
            fileManager: fileManager
        )

        XCTAssertEqual(picker.suggestedDestinationPath(), newer.path)
    }

    func testDestinationMemoryRoundTripsPath() {
        let suiteName = "rollkeep-launcher-memory-\(UUID().uuidString)"
        guard let userDefaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Expected dedicated UserDefaults suite")
            return
        }
        defer {
            userDefaults.removePersistentDomain(forName: suiteName)
        }

        let memory = LauncherDestinationMemory(userDefaults: userDefaults, key: "lastDestination")
        XCTAssertNil(memory.loadLastDestinationPath())

        memory.saveLastDestinationPath("  /Volumes/Archive  ")
        XCTAssertEqual(memory.loadLastDestinationPath(), "/Volumes/Archive")
    }

    func testDestinationAutoPickerPrefersRememberedDestinationFromMemory() {
        let picker = LauncherDestinationAutoPicker(
            memory: StubLauncherDestinationRemembering(initialPath: "/Volumes/Remembered"),
            fallback: StubLauncherDestinationDefaulting(path: "/Volumes/Fallback")
        )

        XCTAssertEqual(picker.suggestedDestinationPath(), "/Volumes/Remembered")
    }

    func testImportPresentationProgressAndRemainingTime() {
        let fraction = LauncherImportPresentation.progressFraction(
            phase: .copy,
            totalCount: 100,
            copiedCount: 50,
            verifiedCount: 0,
            committedCount: 0,
            isSuccess: false
        )
        XCTAssertGreaterThan(fraction, 0.40)
        XCTAssertLessThan(fraction, 0.50)

        let remaining = LauncherImportPresentation.estimatedRemainingText(
            now: Date(timeIntervalSince1970: 30),
            runStartedAt: Date(timeIntervalSince1970: 0),
            progressFraction: 0.5
        )
        XCTAssertEqual(remaining, "About 30 seconds remaining")
    }

    func testLocatorUsesOverridePathWhenExecutable() throws {
        let fileManager = FileManager.default
        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("rollkeep-launcher-locator-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempRoot) }

        let executable = tempRoot.appendingPathComponent("rollkeep", isDirectory: false)
        fileManager.createFile(atPath: executable.path, contents: Data("#!/bin/sh\nexit 0\n".utf8))
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let resolved = RollkeepCLIExecutableLocator.resolve(
            environment: ["ROLLKEEP_CLI_PATH": executable.path],
            launcherExecutableURL: nil
        )

        XCTAssertEqual(resolved?.path, executable.path)
    }

    func testLocatorUsesBundledSiblingCLIWhenPresent() throws {
        let fileManager = FileManager.default
        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("rollkeep-launcher-bundle-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempRoot) }

        let macOSDirectory = tempRoot
            .appendingPathComponent("RollKeep.app", isDirectory: true)
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("MacOS", isDirectory: true)
        try fileManager.createDirectory(at: macOSDirectory, withIntermediateDirectories: true)

        let launcher = macOSDirectory.appendingPathComponent("rollkeep-launcher", isDirectory: false)
        let cli = macOSDirectory.appendingPathComponent("rollkeep", isDirectory: false)

        fileManager.createFile(atPath: launcher.path, contents: Data("#!/bin/sh\nexit 0\n".utf8))
        fileManager.createFile(atPath: cli.path, contents: Data("#!/bin/sh\nexit 0\n".utf8))
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)

        let resolved = RollkeepCLIExecutableLocator.resolve(
            environment: [:],
            launcherExecutableURL: launcher
        )

        XCTAssertEqual(resolved?.path, cli.path)
    }

    @MainActor
    func testViewModelStateMovesFromIdleToReadyWhenPathsBecomeValid() throws {
        let fileManager = FileManager.default
        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("rollkeep-launcher-viewmodel-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempRoot) }

        let source = tempRoot.appendingPathComponent("source", isDirectory: true)
        let destination = tempRoot.appendingPathComponent("dest", isDirectory: true)
        try fileManager.createDirectory(at: source, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)

        let viewModel = LauncherViewModel(
            destinationRemembering: StubLauncherDestinationRemembering(initialPath: nil),
            destinationDefaulting: StubLauncherDestinationDefaulting(path: nil)
        )
        XCTAssertEqual(viewModel.uiState, .idle)

        viewModel.sourcePath = source.path
        XCTAssertEqual(viewModel.uiState, .idle)

        viewModel.destinationPath = destination.path
        XCTAssertEqual(viewModel.uiState, .ready)
        XCTAssertEqual(viewModel.statusMessage, "Ready to ingest.")
        XCTAssertTrue(viewModel.canStart)
    }

    @MainActor
    func testViewModelShowsPartialInventoryWhileScanningAndKeepsFinalInventory() throws {
        let fileManager = FileManager.default
        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("rollkeep-launcher-live-inventory-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempRoot) }

        let source = tempRoot.appendingPathComponent("source", isDirectory: true)
        try fileManager.createDirectory(at: source, withIntermediateDirectories: true)

        let partialSnapshot = makeScanProgressSnapshot(
            itemCount: 4,
            photoCount: 3,
            videoCount: 1,
            totalBytes: 3200,
            distribution: [
                CameraDistributionEntry(cameraLabel: "canon-eos-r5", fileCount: 3),
                CameraDistributionEntry(cameraLabel: CameraLabeler.unknownLabel, fileCount: 1),
            ]
        )
        let finalSummary = makeScanSummary(
            itemCount: 4,
            photoCount: 3,
            videoCount: 1,
            totalBytes: 3200,
            distribution: [
                CameraDistributionEntry(cameraLabel: "canon-eos-r5", fileCount: 3),
                CameraDistributionEntry(cameraLabel: CameraLabeler.unknownLabel, fileCount: 1),
            ]
        )

        let viewModel = LauncherViewModel(
            destinationRemembering: StubLauncherDestinationRemembering(initialPath: nil),
            destinationDefaulting: StubLauncherDestinationDefaulting(path: nil),
            sourceScanner: StubLauncherSourceScanner(
                progressSnapshots: [partialSnapshot],
                finalSummary: finalSummary,
                pauseAfterProgress: 0.15
            )
        )

        viewModel.sourcePath = source.path

        XCTAssertTrue(waitUntil {
            viewModel.isSourceScanning && viewModel.setupInventory?.itemCount == 4
        })
        XCTAssertEqual(viewModel.setupInventory?.detectedCameraCount, 1)
        XCTAssertEqual(viewModel.setupInventoryCameraEntries.map(\.displayLabel), ["canon-eos-r5", "Unknown camera"])
        XCTAssertEqual(viewModel.setupInventoryCameraEntries.map(\.fileCount), [3, 1])

        XCTAssertTrue(waitUntil {
            !viewModel.isSourceScanning && viewModel.setupInventory?.itemCount == 4
        })
        XCTAssertEqual(viewModel.setupInventory?.photoCount, 3)
        XCTAssertEqual(viewModel.setupInventory?.videoCount, 1)
    }

    @MainActor
    func testViewModelPreparesDefaultSourceOnLaunch() throws {
        let fileManager = FileManager.default
        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("rollkeep-launcher-default-source-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempRoot) }

        let source = tempRoot.appendingPathComponent("source", isDirectory: true)
        try fileManager.createDirectory(at: source, withIntermediateDirectories: true)

        let viewModel = LauncherViewModel(
            sourceDefaulting: StubLauncherSourceDefaulting(path: source.path),
            destinationRemembering: StubLauncherDestinationRemembering(initialPath: nil),
            destinationDefaulting: StubLauncherDestinationDefaulting(path: nil)
        )
        viewModel.prepareDefaultsOnLaunch()

        XCTAssertEqual(viewModel.sourcePath, source.path)
        XCTAssertEqual(viewModel.uiState, .idle)
        XCTAssertEqual(viewModel.statusMessage, "Choose a writable destination to begin.")
    }

    @MainActor
    func testViewModelPreparesDefaultDestinationOnLaunch() throws {
        let fileManager = FileManager.default
        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("rollkeep-launcher-default-destination-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempRoot) }

        let destination = tempRoot.appendingPathComponent("archive", isDirectory: true)
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)

        let viewModel = LauncherViewModel(
            sourceDefaulting: StubLauncherSourceDefaulting(path: nil),
            destinationRemembering: StubLauncherDestinationRemembering(initialPath: nil),
            destinationDefaulting: StubLauncherDestinationDefaulting(path: destination.path)
        )
        viewModel.prepareDefaultsOnLaunch()

        XCTAssertEqual(viewModel.destinationPath, destination.path)
        XCTAssertEqual(viewModel.uiState, .idle)
        XCTAssertEqual(viewModel.statusMessage, "Choose a readable source to begin.")
    }

    @MainActor
    func testViewModelRemembersDestinationWhenPathIsSet() throws {
        let fileManager = FileManager.default
        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("rollkeep-launcher-remember-destination-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempRoot) }

        let destination = tempRoot.appendingPathComponent("archive", isDirectory: true)
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)

        let memory = StubLauncherDestinationRemembering(initialPath: nil)
        let viewModel = LauncherViewModel(
            sourceDefaulting: StubLauncherSourceDefaulting(path: nil),
            destinationRemembering: memory,
            destinationDefaulting: StubLauncherDestinationDefaulting(path: nil)
        )

        viewModel.destinationPath = destination.path

        XCTAssertEqual(memory.savedPaths, [destination.path])
    }

    @MainActor
    func testViewModelPreparesRememberedDestinationEvenWhenValidationFails() {
        let viewModel = LauncherViewModel(
            sourceDefaulting: StubLauncherSourceDefaulting(path: nil),
            destinationRemembering: StubLauncherDestinationRemembering(initialPath: nil),
            destinationDefaulting: StubLauncherDestinationDefaulting(path: "/Volumes/Archive")
        )

        viewModel.prepareDefaultsOnLaunch()

        XCTAssertEqual(viewModel.destinationPath, "/Volumes/Archive")
    }

    @MainActor
    func testViewModelLaunchDefaultDoesNotOverrideExistingSource() throws {
        let fileManager = FileManager.default
        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("rollkeep-launcher-existing-source-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempRoot) }

        let existingSource = tempRoot.appendingPathComponent("existing", isDirectory: true)
        let suggestedSource = tempRoot.appendingPathComponent("suggested", isDirectory: true)
        try fileManager.createDirectory(at: existingSource, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: suggestedSource, withIntermediateDirectories: true)

        let viewModel = LauncherViewModel(
            sourceDefaulting: StubLauncherSourceDefaulting(path: suggestedSource.path),
            destinationRemembering: StubLauncherDestinationRemembering(initialPath: nil),
            destinationDefaulting: StubLauncherDestinationDefaulting(path: nil)
        )
        viewModel.sourcePath = existingSource.path
        viewModel.prepareDefaultsOnLaunch()

        XCTAssertEqual(viewModel.sourcePath, existingSource.path)
    }

    @MainActor
    func testViewModelLaunchDefaultDoesNotOverrideExistingDestination() throws {
        let fileManager = FileManager.default
        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("rollkeep-launcher-existing-destination-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempRoot) }

        let existingDestination = tempRoot.appendingPathComponent("existing", isDirectory: true)
        let suggestedDestination = tempRoot.appendingPathComponent("suggested", isDirectory: true)
        try fileManager.createDirectory(at: existingDestination, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: suggestedDestination, withIntermediateDirectories: true)

        let viewModel = LauncherViewModel(
            sourceDefaulting: StubLauncherSourceDefaulting(path: nil),
            destinationRemembering: StubLauncherDestinationRemembering(initialPath: nil),
            destinationDefaulting: StubLauncherDestinationDefaulting(path: suggestedDestination.path)
        )
        viewModel.destinationPath = existingDestination.path
        viewModel.prepareDefaultsOnLaunch()

        XCTAssertEqual(viewModel.destinationPath, existingDestination.path)
    }

    @MainActor
    func testViewModelCompletionTextForIdempotentRerun() {
        let viewModel = LauncherViewModel(
            destinationRemembering: StubLauncherDestinationRemembering(initialPath: nil),
            destinationDefaulting: StubLauncherDestinationDefaulting(path: nil)
        )
        viewModel.finalizedCommittedCount = 0
        viewModel.finalizedDuplicateNotCopiedCount = 3
        viewModel.idempotentRerunDetected = true

        XCTAssertTrue(viewModel.isIdempotentRerun)
        XCTAssertEqual(viewModel.completionItemsText, "No new items imported; 3 items already exist in the library")
        XCTAssertEqual(viewModel.completionOutcomeText, "Idempotent rerun confirmed. Existing files were preserved without overwrite.")
    }

    @MainActor
    func testViewModelDoesNotAllowStartWhileRunning() throws {
        let fileManager = FileManager.default
        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("rollkeep-launcher-running-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempRoot) }

        let source = tempRoot.appendingPathComponent("source", isDirectory: true)
        let destination = tempRoot.appendingPathComponent("dest", isDirectory: true)
        try fileManager.createDirectory(at: source, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)

        let viewModel = LauncherViewModel(
            destinationRemembering: StubLauncherDestinationRemembering(initialPath: nil),
            destinationDefaulting: StubLauncherDestinationDefaulting(path: nil)
        )
        viewModel.sourcePath = source.path
        viewModel.destinationPath = destination.path
        XCTAssertTrue(viewModel.canStart)

        viewModel.uiState = .running
        XCTAssertFalse(viewModel.canStart)
        XCTAssertTrue(viewModel.isRunning)

        viewModel.sourcePath = ""
        XCTAssertEqual(viewModel.uiState, .running)
    }
}

private struct StubLauncherSourceDefaulting: LauncherSourceDefaulting {
    let path: String?

    func suggestedSourcePath() -> String? {
        path
    }
}

private struct StubLauncherDestinationDefaulting: LauncherDestinationDefaulting {
    let path: String?

    func suggestedDestinationPath() -> String? {
        path
    }
}

private final class StubLauncherDestinationRemembering: LauncherDestinationRemembering {
    private let initialPath: String?
    private(set) var savedPaths: [String] = []

    init(initialPath: String?) {
        self.initialPath = initialPath
    }

    func loadLastDestinationPath() -> String? {
        initialPath
    }

    func saveLastDestinationPath(_ path: String) {
        savedPaths.append(path)
    }
}

private struct StubLauncherSourceScanner: LauncherSourceScanning {
    let progressSnapshots: [ScanProgressSnapshot]
    let finalSummary: ScanSummary
    let pauseAfterProgress: TimeInterval

    func scan(
        sourcePath: String,
        progress: (@Sendable (ScanProgressSnapshot) -> Void)?
    ) throws -> ScanSummary {
        for snapshot in progressSnapshots {
            progress?(snapshot)
        }

        if pauseAfterProgress > 0 {
            Thread.sleep(forTimeInterval: pauseAfterProgress)
        }

        return finalSummary
    }
}

@MainActor
private func waitUntil(
    timeout: TimeInterval = 1.0,
    pollInterval: TimeInterval = 0.01,
    condition: () -> Bool
) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() {
            return true
        }
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(pollInterval))
    }
    return condition()
}

private func makeScanProgressSnapshot(
    itemCount: Int,
    photoCount: Int,
    videoCount: Int,
    totalBytes: Int64,
    distribution: [CameraDistributionEntry]
) -> ScanProgressSnapshot {
    ScanProgressSnapshot(
        itemCount: itemCount,
        photoCount: photoCount,
        videoCount: videoCount,
        totalBytes: totalBytes,
        cameraAssessment: makeCameraAssessment(distribution: distribution)
    )
}

private func makeScanSummary(
    itemCount: Int,
    photoCount: Int,
    videoCount: Int,
    totalBytes: Int64,
    distribution: [CameraDistributionEntry]
) -> ScanSummary {
    var candidates: [MediaCandidate] = []
    for index in 0..<photoCount {
        candidates.append(MediaCandidate(
            absolutePath: "/source/DCIM/IMG_\(index).JPG",
            relativePath: "DCIM/IMG_\(index).JPG",
            mediaType: .photo,
            sizeBytes: 100,
            mtime: Date(timeIntervalSince1970: 1_700_000_000 + Double(index)),
            photoMetadata: PhotoMetadata(
                captureDateTime: Date(timeIntervalSince1970: 1_700_000_100 + Double(index)),
                captureDateSource: .dateTimeOriginal,
                cameraMake: nil,
                cameraModel: nil,
                cameraSerial: nil
            )
        ))
    }

    for index in 0..<videoCount {
        candidates.append(MediaCandidate(
            absolutePath: "/source/PRIVATE/VID_\(index).MP4",
            relativePath: "PRIVATE/VID_\(index).MP4",
            mediaType: .video,
            sizeBytes: 100,
            mtime: Date(timeIntervalSince1970: 1_700_000_500 + Double(index)),
            videoMetadata: VideoMetadata(
                captureDateTime: Date(timeIntervalSince1970: 1_700_000_600 + Double(index)),
                captureDateSource: .creationTime,
                usedFallback: false
            )
        ))
    }

    XCTAssertEqual(candidates.count, itemCount)

    return ScanSummary(
        candidates: candidates,
        photoCount: photoCount,
        videoCount: videoCount,
        photoBytes: Int64(photoCount) * 100,
        videoBytes: totalBytes - (Int64(photoCount) * 100),
        filesInTypicalLocations: itemCount,
        filesOutsideTypicalLocations: 0,
        errors: [],
        cameraAssessment: makeCameraAssessment(distribution: distribution)
    )
}

private func makeCameraAssessment(distribution: [CameraDistributionEntry]) -> CameraCardAssessment {
    let knownDistribution = distribution.filter { $0.cameraLabel != CameraLabeler.unknownLabel }
    let mixed = knownDistribution.count > 1
    return CameraCardAssessment(
        cameraLabel: mixed ? CameraLabeler.mixedLabel : (knownDistribution.first?.cameraLabel ?? CameraLabeler.unknownLabel),
        mixedCameraDetected: mixed,
        totalCandidates: distribution.map(\.fileCount).reduce(0, +),
        knownCameraFileCount: knownDistribution.map(\.fileCount).reduce(0, +),
        unknownCameraFileCount: distribution.first(where: { $0.cameraLabel == CameraLabeler.unknownLabel })?.fileCount ?? 0,
        distribution: distribution
    )
}
