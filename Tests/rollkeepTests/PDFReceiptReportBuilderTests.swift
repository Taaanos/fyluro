import Foundation
import XCTest
@testable import RollKeepCore

final class PDFReceiptReportBuilderTests: XCTestCase {
    private let builder = PDFReceiptReportBuilder()

    func testStatusMappingAcrossModes() {
        let verified = builder.build(input: makeInput())
        XCTAssertEqual(verified.statusLabel, "VERIFIED")

        let dryRun = builder.build(input: makeInput(dryRun: true))
        XCTAssertEqual(dryRun.statusLabel, "DRY RUN")

        let failed = builder.build(input: makeInput(finalStatus: "aborted"))
        XCTAssertEqual(failed.statusLabel, "FAILED")
    }

    func testAlertGenerationIncludesFailureAndPolicyAlerts() {
        let report = builder.build(input: makeInput(
            summary: [
                "totals_by_outcome": ["errors": 3],
            ],
            finalStatus: "aborted",
            dryRun: true,
            failurePhase: "verify",
            failureReason: "hash mismatch"
        ))

        XCTAssertTrue(report.alerts.contains { $0.contains("Ingest failed during verify: hash mismatch") })
        XCTAssertTrue(report.alerts.contains { $0.contains("Dry run mode was enabled") })

        let completionWithErrors = builder.build(input: makeInput(summary: [
            "totals_by_outcome": ["errors": 2],
        ]))
        XCTAssertTrue(completionWithErrors.alerts.contains { $0.contains("recorded error event") })
    }

    func testContextRowsAreTrimmedToSixEntries() {
        let report = builder.build(input: makeInput())

        XCTAssertEqual(report.contextRows.count, 6)
        XCTAssertEqual(report.contextRows.map(\.0), [
            "Generated", "Source", "Destination", "Path Scheme", "Receipt sink", "Dry run",
        ])
        XCTAssertNil(value(for: "Session ID", in: report.contextRows))
        XCTAssertNil(value(for: "Verification", in: report.contextRows))
        XCTAssertNil(value(for: "Detailed event log", in: report.contextRows))
    }

    func testFileOutcomeCapturesSourcePathAndCollisionRenamed() throws {
        let report = builder.build(input: makeInput(summary: [
            "per_file_outcomes": [
                [
                    "media_type": "photo",
                    "outcome": "stage_and_commit",
                    "executed": true,
                    "path": "IMG_0001.JPG",
                    "source_path": "/source/DCIM/100/IMG_0001.JPG",
                    "final_path": "/dest/2023/202311/canon/Photos/IMG_0001.JPG",
                    "collision_suffix": "-1",
                ],
            ],
        ]))

        let outcome = try XCTUnwrap(report.fileOutcomes.first)
        XCTAssertEqual(outcome.sourcePath, "/source/DCIM/100/IMG_0001.JPG")
        XCTAssertTrue(outcome.collisionRenamed)
    }

    func testPerFileOutcomesAreCappedToPreviewLimit() {
        var outcomes: [[String: Any]] = []
        for index in 0..<100 {
            outcomes.append([
                "media_type": "photo",
                "outcome": "stage_and_commit",
                "executed": true,
                "path": "DCIM/IMG_\(index).JPG",
                "final_path": "/dest/IMG_\(index).JPG",
            ])
        }

        let report = builder.build(input: makeInput(summary: [
            "per_file_outcomes": outcomes,
        ]))

        XCTAssertEqual(report.totalFileOutcomeCount, 100)
        XCTAssertEqual(report.fileOutcomes.count, 80)
    }

    func testUnknownFallbacksWhenSummaryFieldsMissingOrInvalid() {
        let report = builder.build(input: makeInput(summary: [
            "date_range": ["start": "unknown", "end": "unknown"],
            "camera_labels": [["label": NSNull(), "file_count": "abc"]],
            "per_file_outcomes": [["executed": NSNull()]],
        ]))

        XCTAssertEqual(value(for: "Path Scheme", in: report.contextRows), "unknown")
        XCTAssertEqual(report.cameraDistribution.first, "unknown: 0")
        XCTAssertEqual(report.fileOutcomes.first?.mediaType, "unknown")
        XCTAssertEqual(report.fileOutcomes.first?.outcome, "unknown")
        XCTAssertEqual(report.fileOutcomes.first?.path, "unknown")
        XCTAssertEqual(report.fileOutcomes.first?.sourcePath, "unknown")
        XCTAssertEqual(report.fileOutcomes.first?.finalPath, "unknown")
        XCTAssertEqual(report.fileOutcomes.first?.executed, false)
        XCTAssertEqual(report.fileOutcomes.first?.collisionRenamed, false)
    }

    private func makeInput(
        summary: [String: Any] = [:],
        finalStatus: String = "completed",
        dryRun: Bool = false,
        failurePhase: String? = nil,
        failureReason: String? = nil,
        scanSummary: ScanSummary? = nil
    ) -> PDFReceiptReportInput {
        PDFReceiptReportInput(
            sessionID: "session-123",
            sourcePath: "/source",
            destinationPath: "/dest",
            dryRun: dryRun,
            receiptPath: "/dest/_ingest_receipts/session-123.ndjson",
            receiptSinkKind: "destination",
            generatedAt: Date(timeIntervalSince1970: 1_700_001_000),
            finalStatus: finalStatus,
            failurePhase: failurePhase,
            failureReason: failureReason,
            summary: summary,
            scanSummary: scanSummary ?? makeScanSummary()
        )
    }

    private func makeScanSummary() -> ScanSummary {
        ScanSummary(
            candidates: [],
            photoCount: 0,
            videoCount: 0,
            photoBytes: 0,
            videoBytes: 0,
            filesInTypicalLocations: 0,
            filesOutsideTypicalLocations: 0,
            errors: []
        )
    }

    private func value(for key: String, in rows: [(String, String)]) -> String? {
        rows.first(where: { $0.0 == key })?.1
    }
}
