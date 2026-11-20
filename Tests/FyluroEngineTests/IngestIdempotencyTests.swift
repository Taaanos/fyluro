import XCTest
@testable import FyluroEngine

/// Covers the idempotency classification logic that moved out of the CLI's
/// summary renderer into the engine (`IngestIdempotency(finalStatus:dryRun:counts:)`).
final class IngestIdempotencyTests: XCTestCase {
    private func counts(committed: Int, duplicateNotCopied: Int) -> IngestCounts {
        IngestCounts(
            candidates: committed + duplicateNotCopied,
            photos: 0,
            videos: 0,
            copied: committed,
            verified: committed,
            committed: committed,
            duplicateNotCopied: duplicateNotCopied,
            conflictsRenamed: 0,
            errors: 0
        )
    }

    func testAbortedClassifiesAsUnknownDueToFailure() {
        let idempotency = IngestIdempotency(
            finalStatus: "aborted",
            dryRun: false,
            counts: counts(committed: 3, duplicateNotCopied: 1)
        )
        XCTAssertEqual(idempotency.classification, "unknown_due_to_failure")
        XCTAssertEqual(idempotency.newFilesCommitted, 3)
        XCTAssertEqual(idempotency.duplicatesSkipped, 1)
    }

    func testDryRunClassifiesAsNotApplicable() {
        let idempotency = IngestIdempotency(
            finalStatus: "completed",
            dryRun: true,
            counts: counts(committed: 0, duplicateNotCopied: 0)
        )
        XCTAssertEqual(idempotency.classification, "dry_run_not_applicable")
    }

    func testZeroCommittedWithDuplicatesIsIdempotentRerun() {
        let idempotency = IngestIdempotency(
            finalStatus: "completed",
            dryRun: false,
            counts: counts(committed: 0, duplicateNotCopied: 9)
        )
        XCTAssertEqual(idempotency.classification, "idempotent_rerun")
        XCTAssertEqual(idempotency.newFilesCommitted, 0)
        XCTAssertEqual(idempotency.duplicatesSkipped, 9)
    }

    func testCommittedFilesClassifyAsNewFilesCommitted() {
        let idempotency = IngestIdempotency(
            finalStatus: "completed",
            dryRun: false,
            counts: counts(committed: 5, duplicateNotCopied: 2)
        )
        XCTAssertEqual(idempotency.classification, "new_files_committed")
        XCTAssertEqual(idempotency.newFilesCommitted, 5)
        XCTAssertEqual(idempotency.duplicatesSkipped, 2)
    }
}
