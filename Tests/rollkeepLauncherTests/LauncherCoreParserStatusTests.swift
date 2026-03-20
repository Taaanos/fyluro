import XCTest
@testable import rollkeepLauncher
@testable import RollKeepCore

final class LauncherCoreTests: XCTestCase {
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

    func testOutputParserReadsPDFSummaryPath() {
        var parser = CLIOutputParser()
        let update = parser.parse(line: "PDF summary: /tmp/run.summary.pdf")
        XCTAssertEqual(update.pdfSummaryPath, "/tmp/run.summary.pdf")
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
        {"event_index":5,"event_type":"FILE_COPY_STARTED","phase":"copy","data":{"status":"started","executed":true,"path":"DCIM/100CANON/IMG_0001.CR3"}}
        """)
        XCTAssertEqual(copyStarted.copiedIncrement, 1)
        XCTAssertEqual(copyStarted.currentFilePath, "DCIM/100CANON/IMG_0001.CR3")

        let queuedCopy = parser.parse(line: """
        {"event_index":5,"event_type":"FILE_COPY_STARTED","phase":"copy","data":{"status":"queued","executed":true}}
        """)
        XCTAssertEqual(queuedCopy.copiedIncrement, 0)

        let verified = parser.parse(line: """
        {"event_index":6,"event_type":"FILE_VERIFIED","phase":"verify","data":{"outcome":"verified","executed":true}}
        """)
        XCTAssertEqual(verified.verifiedIncrement, 1)

        let verifyStarted = parser.parse(line: """
        {"event_index":6,"event_type":"FILE_VERIFY_STARTED","phase":"verify","data":{"executed":true,"path":"DCIM/100CANON/IMG_0001.CR3"}}
        """)
        XCTAssertEqual(verifyStarted.currentFilePath, "DCIM/100CANON/IMG_0001.CR3")

        let commitStarted = parser.parse(line: """
        {"event_index":7,"event_type":"FILE_COMMIT_STARTED","phase":"commit","data":{"executed":true,"path":"2026/202603/canon-r5/Photos/IMG_0001.CR3"}}
        """)
        XCTAssertEqual(commitStarted.currentFilePath, "2026/202603/canon-r5/Photos/IMG_0001.CR3")

        let committed = parser.parse(line: """
        {"event_index":7,"event_type":"FILE_COMMITTED","phase":"commit","data":{"status":"committed","executed":true}}
        """)
        XCTAssertEqual(committed.committedIncrement, 1)

        let skippedDuplicate = parser.parse(line: """
        {"event_index":8,"event_type":"FILE_COMMITTED","phase":"commit","data":{"status":"skipped_duplicate","executed":true}}
        """)
        XCTAssertEqual(skippedDuplicate.committedIncrement, 0)

        let error = parser.parse(line: """
        {"event_index":8,"event_type":"ERROR","phase":"commit","data":{"error":"Disk full","staging_path":"/dest/_ingest_staging/sid/file.mov","final_path":"/dest/2026/202602/cam/Videos/file.mov"}}
        """)
        XCTAssertEqual(error.errorItem?.eventIndex, 8)
        XCTAssertEqual(error.errorItem?.phase, .commit)
        XCTAssertEqual(error.errorItem?.message, "Disk full")
        XCTAssertEqual(error.errorItem?.paths, [
            "/dest/_ingest_staging/sid/file.mov",
            "/dest/2026/202602/cam/Videos/file.mov",
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

    func testReceiptEventParserReadsScanProgressEvent() {
        var parser = ReceiptEventParser()

        let scan = parser.parse(line: """
        {"event_index":2,"event_type":"SCAN_PROGRESS","phase":"scan","data":{"files_checked":120,"bytes_checked":998877,"candidate_count":12,"photos":{"count":10,"bytes":123456},"videos":{"count":2,"bytes":875421},"path":"DCIM/100MEDIA/IMG_0012.JPG"}}
        """)

        XCTAssertEqual(scan.phase, .scan)
        XCTAssertEqual(scan.scannedFilesCheckedCount, 120)
        XCTAssertEqual(scan.scannedCheckedBytes, 998877)
        XCTAssertEqual(scan.scannedCandidateCount, 12)
        XCTAssertEqual(scan.scanPhotoCount, 10)
        XCTAssertEqual(scan.scanVideoCount, 2)
        XCTAssertEqual(scan.scanPhotoBytes, 123456)
        XCTAssertEqual(scan.scanVideoBytes, 875421)
        XCTAssertEqual(scan.currentFilePath, "DCIM/100MEDIA/IMG_0012.JPG")
    }

    func testCLIOutputParserReadsScanSummaryCountsFromJSONLogLine() {
        var parser = CLIOutputParser()

        let update = parser.parse(line: """
        {"component":"rollkeep-cli","message":"scan_summary","candidate_count":"31","photo_count":"0","video_count":"31","photo_bytes":"0","video_bytes":"2857304064"}
        """)

        XCTAssertEqual(update.phase, .plan)
        XCTAssertEqual(update.scannedCandidateCount, 31)
        XCTAssertEqual(update.scanPhotoCount, 0)
        XCTAssertEqual(update.scanVideoCount, 31)
        XCTAssertEqual(update.scanPhotoBytes, 0)
        XCTAssertEqual(update.scanVideoBytes, 2_857_304_064)
    }

    func testReceiptEventParserReadsFinalOutcomeTotalsFromSummary() {
        var parser = ReceiptEventParser()

        let summary = parser.parse(line: """
        {"event_index":55,"event_type":"SUMMARY","phase":"finalize","data":{"status":"completed","dry_run":false,"totals_by_outcome":{"committed":0,"duplicate_not_copied":9},"phase_timings_ms":[{"phase":"scan","milliseconds":1200},{"phase":"plan","milliseconds":300},{"phase":"copy","milliseconds":2500},{"phase":"verify","milliseconds":1000},{"phase":"commit","milliseconds":800},{"phase":"finalize","milliseconds":200}]}}
        """)

        XCTAssertEqual(summary.finalizedCommittedCount, 0)
        XCTAssertEqual(summary.finalizedDuplicateNotCopiedCount, 9)
        XCTAssertEqual(summary.finalizedIdempotentRerun, true)
        XCTAssertEqual(summary.finalizedTotalDurationMs, 6000)
        XCTAssertEqual(summary.finalizedPhaseTimings?.count, 6)
    }

    func testReceiptEventParserReadsPDFSummaryPathFromSummary() {
        var parser = ReceiptEventParser()

        let summary = parser.parse(line: """
        {"event_index":55,"event_type":"SUMMARY","phase":"finalize","data":{"status":"completed","dry_run":false,"pdf_summary_path":"/dest/_ingest_receipts/run.summary.pdf","totals_by_outcome":{"committed":1,"duplicate_not_copied":0}}}
        """)

        XCTAssertEqual(summary.pdfSummaryPath, "/dest/_ingest_receipts/run.summary.pdf")
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

    func testReceiptEventParserExtractsTouchedPaths() {
        var parser = ReceiptEventParser()

        let summary = parser.parse(line: """
        {"event_index":25,"event_type":"SUMMARY","phase":"finalize","data":{"touched_paths":{"created_directories":["/dest/2026/202602/cam/Photos"],"written_staging_files":["/dest/_ingest_staging/sid/a.jpg"],"move_operations":[{"from":"/dest/_ingest_staging/sid/a.jpg","to":"/dest/2026/202602/cam/Photos/a.jpg"}]}}}
        """)

        XCTAssertEqual(summary.phase, .finalize)
        XCTAssertEqual(summary.touchedPaths?.sorted(), [
            "/dest/2026/202602/cam/Photos",
            "/dest/_ingest_staging/sid/a.jpg",
            "/dest/2026/202602/cam/Photos/a.jpg",
        ].sorted())
        XCTAssertEqual(summary.createdDirectories, ["/dest/2026/202602/cam/Photos"])
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

    func testLauncherWindowMetricsKeepSetupStateTallEnoughForScanResults() {
        XCTAssertEqual(LauncherWindowMetrics.preferredContentHeight(for: .idle), LauncherWindowMetrics.setupHeight)
        XCTAssertEqual(LauncherWindowMetrics.preferredContentHeight(for: .ready), LauncherWindowMetrics.setupHeight)
        XCTAssertEqual(LauncherWindowMetrics.preferredContentHeight(for: .running), LauncherWindowMetrics.compactHeight)
        XCTAssertEqual(
            LauncherWindowMetrics.preferredContentHeight(for: .idle, measuredHeight: LauncherWindowMetrics.setupHeight + 42),
            LauncherWindowMetrics.setupHeight + 42
        )
        XCTAssertEqual(
            LauncherWindowMetrics.preferredContentHeight(for: .failure, measuredHeight: LauncherWindowMetrics.compactHeight - 20),
            LauncherWindowMetrics.compactHeight
        )
        XCTAssertGreaterThan(LauncherWindowMetrics.setupHeight, LauncherWindowMetrics.compactHeight)
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
            phase: .copy,
            copiedCount: 1,
            progressFraction: 0.5
        )
        XCTAssertEqual(remaining, "About 30 seconds remaining")
    }
}
