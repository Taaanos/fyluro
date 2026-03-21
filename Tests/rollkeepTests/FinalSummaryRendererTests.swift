import Foundation
import XCTest
@testable import rollkeep

final class FinalSummaryRendererTests: XCTestCase {
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
        let payload = FinalSummaryPayload(
            sessionID: "session-1",
            finalStatus: "aborted",
            exitCode: RollkeepExitCode.verifyFailed.rawValue,
            dryRun: false,
            receiptPath: "/tmp/receipt.ndjson",
            receiptSink: .destination,
            stagingSessionPath: "/tmp/_ingest_staging/session-1",
            pdfSummaryPath: nil,
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
            )
        )

        let text = FinalSummaryRenderer().renderHuman(payload)
        XCTAssertTrue(text.contains("Status: FAILED"))
        XCTAssertTrue(text.contains("Exit code: 2"))
        XCTAssertTrue(text.contains("Failure"))
        XCTAssertTrue(text.contains("staging: /tmp/_ingest_staging/session-1"))
        XCTAssertTrue(text.contains("receipt: /tmp/receipt.ndjson"))
        XCTAssertTrue(text.contains("first_errors"))
    }

    func testHumanSummaryUsesDryRunStatusLabel() {
        let payload = FinalSummaryPayload(
            sessionID: "session-2",
            finalStatus: "completed",
            exitCode: 0,
            dryRun: true,
            receiptPath: "/tmp/receipt.ndjson",
            receiptSink: .destination,
            stagingSessionPath: "/tmp/_ingest_staging/session-2",
            pdfSummaryPath: nil,
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
            )
        )

        let text = FinalSummaryRenderer().renderHuman(payload)
        XCTAssertTrue(text.contains("Status: DRY RUN (scan+plan)"))
        XCTAssertTrue(text.contains("Idempotency: dry_run_not_applicable"))
    }

    func testHumanSummaryIncludesIdempotentRerunLabel() {
        let payload = FinalSummaryPayload(
            sessionID: "session-3",
            finalStatus: "completed",
            exitCode: 0,
            dryRun: false,
            receiptPath: "/tmp/receipt.ndjson",
            receiptSink: .destination,
            stagingSessionPath: "/tmp/_ingest_staging/session-3",
            pdfSummaryPath: nil,
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
            )
        )

        let text = FinalSummaryRenderer().renderHuman(payload)
        XCTAssertTrue(text.contains("Idempotency: idempotent_rerun"))
    }

    func testJSONSummaryIncludesIdempotencyClassification() throws {
        let payload = FinalSummaryPayload(
            sessionID: "session-4",
            finalStatus: "completed",
            exitCode: 0,
            dryRun: false,
            receiptPath: "/tmp/receipt.ndjson",
            receiptSink: .destination,
            stagingSessionPath: "/tmp/_ingest_staging/session-4",
            pdfSummaryPath: nil,
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
            )
        )

        let json = FinalSummaryRenderer().renderJSON(payload)
        let jsonData = try XCTUnwrap(json.data(using: .utf8))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: jsonData) as? [String: Any])
        let idempotency = try XCTUnwrap(object["idempotency"] as? [String: Any])
        XCTAssertEqual(idempotency["classification"] as? String, "idempotent_rerun")
        XCTAssertEqual(idempotency["new_files_committed"] as? Int, 0)
        XCTAssertEqual(idempotency["duplicates_skipped"] as? Int, 2)
    }
}
