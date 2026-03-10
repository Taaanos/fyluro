import Foundation
import XCTest
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

        let viewModel = LauncherViewModel()
        XCTAssertEqual(viewModel.uiState, .idle)

        viewModel.sourcePath = source.path
        XCTAssertEqual(viewModel.uiState, .idle)

        viewModel.destinationPath = destination.path
        XCTAssertEqual(viewModel.uiState, .ready)
        XCTAssertEqual(viewModel.statusMessage, "Ready to ingest.")
        XCTAssertTrue(viewModel.canStart)
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

        let viewModel = LauncherViewModel()
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
