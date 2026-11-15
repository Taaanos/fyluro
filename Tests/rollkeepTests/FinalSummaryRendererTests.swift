import Foundation
import RollKeepEngine
import XCTest
@testable import rollkeep

final class FinalSummaryRendererTests: XCTestCase {
    private func makeResult(
        sessionID: String,
        finalStatus: String,
        dryRun: Bool,
        stagingSessionPath: String,
        failurePhase: IngestPhase?,
        failureReason: String?,
        firstErrors: [String],
        phaseTimings: [IngestPhaseTiming],
        counts: IngestCounts,
        idempotency: IngestIdempotency
    ) -> IngestSessionResult {
        IngestSessionResult(
            sessionID: sessionID,
            finalStatus: finalStatus,
            dryRun: dryRun,
            receiptPath: "/tmp/receipt.ndjson",
            receiptSink: "destination",
            stagingSessionPath: stagingSessionPath,
            pdfSummaryPath: nil,
            failurePhase: failurePhase,
            failureReason: failureReason,
            firstErrors: firstErrors,
            phaseTimings: phaseTimings,
            counts: counts,
            idempotency: idempotency
        )
    }

    func testExitCodeResolutionMapsVerifyFailureToTwo() {
        let code = RollkeepExitCode.resolve(finalStatus: "aborted", failurePhase: .verify)
        XCTAssertEqual(code, .verifyFailed)
        XCTAssertEqual(code.rawValue, 2)
    }

    func testExitCodeResolutionMapsSuccessToZero() {
        let code = RollkeepExitCode.resolve(finalStatus: "completed", failurePhase: .copy)
        XCTAssertEqual(code, .success)
        XCTAssertEqual(code.rawValue, 0)
    }

    func testHumanSummaryIncludesFailureReceiptAndStagingContext() {
        let result = makeResult(
            sessionID: "session-1",
            finalStatus: "aborted",
            dryRun: false,
            stagingSessionPath: "/tmp/_ingest_staging/session-1",
            failurePhase: .verify,
            failureReason: "Read-back verification failed: hash mismatch",
            firstErrors: [
                "[verify] hash mismatch for IMG_0001.JPG",
                "[verify] expected bytes 1024, got 1024",
            ],
            phaseTimings: [
                .init(phase: .scan, milliseconds: 120),
                .init(phase: .plan, milliseconds: 90),
                .init(phase: .copy, milliseconds: 350),
                .init(phase: .verify, milliseconds: 210),
                .init(phase: .commit, milliseconds: 0),
                .init(phase: .finalize, milliseconds: 40),
            ],
            counts: .init(
                candidates: 3,
                photos: 2,
                videos: 1,
                copied: 1,
                verified: 0,
                committed: 0,
                duplicateNotCopied: 0,
                conflictsRenamed: 0,
                errors: 1
            ),
            idempotency: .init(classification: "unknown_due_to_failure", newFilesCommitted: 0, duplicatesSkipped: 0)
        )

        let text = FinalSummaryRenderer().renderHuman(result, exitCode: RollkeepExitCode.verifyFailed.rawValue)
        XCTAssertTrue(text.contains("Status: FAILED"))
        XCTAssertTrue(text.contains("Exit code: 2"))
        XCTAssertTrue(text.contains("Failure"))
        XCTAssertTrue(text.contains("staging: /tmp/_ingest_staging/session-1"))
        XCTAssertTrue(text.contains("receipt: /tmp/receipt.ndjson"))
        XCTAssertTrue(text.contains("first_errors"))
    }

    func testHumanSummaryUsesDryRunStatusLabel() {
        let result = makeResult(
            sessionID: "session-2",
            finalStatus: "completed",
            dryRun: true,
            stagingSessionPath: "/tmp/_ingest_staging/session-2",
            failurePhase: nil,
            failureReason: nil,
            firstErrors: [],
            phaseTimings: [],
            counts: .init(
                candidates: 1,
                photos: 1,
                videos: 0,
                copied: 0,
                verified: 0,
                committed: 0,
                duplicateNotCopied: 0,
                conflictsRenamed: 0,
                errors: 0
            ),
            idempotency: .init(classification: "dry_run_not_applicable", newFilesCommitted: 0, duplicatesSkipped: 0)
        )

        let text = FinalSummaryRenderer().renderHuman(result, exitCode: 0)
        XCTAssertTrue(text.contains("Status: DRY RUN (scan+plan)"))
        XCTAssertTrue(text.contains("Idempotency: dry_run_not_applicable"))
    }

    func testHumanSummaryIncludesIdempotentRerunLabel() {
        let result = makeResult(
            sessionID: "session-3",
            finalStatus: "completed",
            dryRun: false,
            stagingSessionPath: "/tmp/_ingest_staging/session-3",
            failurePhase: nil,
            failureReason: nil,
            firstErrors: [],
            phaseTimings: [],
            counts: .init(
                candidates: 9,
                photos: 8,
                videos: 1,
                copied: 9,
                verified: 9,
                committed: 0,
                duplicateNotCopied: 9,
                conflictsRenamed: 0,
                errors: 0
            ),
            idempotency: .init(classification: "idempotent_rerun", newFilesCommitted: 0, duplicatesSkipped: 9)
        )

        let text = FinalSummaryRenderer().renderHuman(result, exitCode: 0)
        XCTAssertTrue(text.contains("Idempotency: idempotent_rerun"))
    }

    func testJSONSummaryIncludesIdempotencyClassification() throws {
        let result = makeResult(
            sessionID: "session-4",
            finalStatus: "completed",
            dryRun: false,
            stagingSessionPath: "/tmp/_ingest_staging/session-4",
            failurePhase: nil,
            failureReason: nil,
            firstErrors: [],
            phaseTimings: [],
            counts: .init(
                candidates: 2,
                photos: 2,
                videos: 0,
                copied: 2,
                verified: 2,
                committed: 0,
                duplicateNotCopied: 2,
                conflictsRenamed: 0,
                errors: 0
            ),
            idempotency: .init(classification: "idempotent_rerun", newFilesCommitted: 0, duplicatesSkipped: 2)
        )

        let json = FinalSummaryRenderer().renderJSON(result, exitCode: 0)
        let jsonData = try XCTUnwrap(json.data(using: .utf8))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: jsonData) as? [String: Any])
        let idempotency = try XCTUnwrap(object["idempotency"] as? [String: Any])
        XCTAssertEqual(idempotency["classification"] as? String, "idempotent_rerun")
        XCTAssertEqual(idempotency["new_files_committed"] as? Int, 0)
        XCTAssertEqual(idempotency["duplicates_skipped"] as? Int, 2)
    }

    func testHumanSummarySanitizesControlCharactersAndBidiOverrides() {
        let hostileReason = "failed reading \u{001B}[31m/Volumes/CARD/\u{202E}gpj.mp4\u{001B}[0m"
        let hostileError = "copy failed on \u{001B}[2Jclip_\u{202E}gpj.mov\r\n"
        let result = makeResult(
            sessionID: "session-\u{001B}[31m5",
            finalStatus: "aborted",
            dryRun: false,
            stagingSessionPath: "/tmp/_ingest_staging/\u{202E}s5",
            failurePhase: .copy,
            failureReason: hostileReason,
            firstErrors: [hostileError],
            phaseTimings: [],
            counts: .init(
                candidates: 1,
                photos: 0,
                videos: 1,
                copied: 0,
                verified: 0,
                committed: 0,
                duplicateNotCopied: 0,
                conflictsRenamed: 0,
                errors: 1
            ),
            idempotency: .init(classification: "partial_or_aborted", newFilesCommitted: 0, duplicatesSkipped: 0)
        )

        let text = FinalSummaryRenderer().renderHuman(result, exitCode: 5)
        XCTAssertFalse(text.contains("\u{001B}"))
        XCTAssertFalse(text.contains("\u{202E}"))
        XCTAssertTrue(text.contains("\\u{001B}[31m"))
        XCTAssertTrue(text.contains("\\u{202E}gpj.mp4"))
        XCTAssertTrue(text.contains("\\u{001B}[2Jclip_\\u{202E}gpj.mov\\u{000D}\\u{000A}"))
    }

    func testJSONSummaryPreservesExactErrorValues() throws {
        let hostileError = "error on /Volumes/\u{202E}gpj.mp4"
        let result = makeResult(
            sessionID: "session-6",
            finalStatus: "aborted",
            dryRun: false,
            stagingSessionPath: "/tmp/_ingest_staging/session-6",
            failurePhase: .copy,
            failureReason: "copy failed",
            firstErrors: [hostileError],
            phaseTimings: [],
            counts: .init(
                candidates: 1,
                photos: 0,
                videos: 1,
                copied: 0,
                verified: 0,
                committed: 0,
                duplicateNotCopied: 0,
                conflictsRenamed: 0,
                errors: 1
            ),
            idempotency: .init(classification: "partial_or_aborted", newFilesCommitted: 0, duplicatesSkipped: 0)
        )

        let json = FinalSummaryRenderer().renderJSON(result, exitCode: 5)
        let jsonData = try XCTUnwrap(json.data(using: .utf8))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: jsonData) as? [String: Any])
        let failure = try XCTUnwrap(object["failure"] as? [String: Any])
        let firstErrors = try XCTUnwrap(failure["first_errors"] as? [String])
        XCTAssertEqual(firstErrors, [hostileError])
    }
}
