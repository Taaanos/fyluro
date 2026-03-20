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

        let skippedVerification = builder.build(input: makeInput(verificationEnabled: false))
        XCTAssertEqual(skippedVerification.statusLabel, "COMPLETED (verification skipped)")

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
            verificationEnabled: false,
            failurePhase: "verify",
            failureReason: "hash mismatch"
        ))

        XCTAssertTrue(report.alerts.contains { $0.contains("Ingest failed during verify: hash mismatch") })
        XCTAssertTrue(report.alerts.contains { $0.contains("Dry run mode was enabled") })
        XCTAssertTrue(report.alerts.contains { $0.contains("Verification read-back was skipped") })

        let completionWithErrors = builder.build(input: makeInput(summary: [
            "totals_by_outcome": ["errors": 2],
        ]))
        XCTAssertTrue(completionWithErrors.alerts.contains { $0.contains("recorded error event") })
    }

    func testPhaseTimingsAreSortedByPipelineOrder() {
        let report = builder.build(input: makeInput(summary: [
            "phase_timings_ms": [
                ["phase": "commit", "milliseconds": 500],
                ["phase": "scan", "milliseconds": 100],
                ["phase": "verify", "milliseconds": 400],
                ["phase": "plan", "milliseconds": 200],
                ["phase": "copy", "milliseconds": 300],
                ["phase": "finalize", "milliseconds": 600],
                ["phase": "custom", "milliseconds": 1],
            ],
        ]))

        XCTAssertEqual(report.phaseTimings.map(\.phase), [
            "scan", "plan", "copy", "verify", "commit", "finalize", "custom",
        ])
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
        XCTAssertEqual(value(for: "Card label", in: report.inventoryRows), "unknown")
        XCTAssertEqual(report.cameraDistribution.first, "unknown: 0")
        XCTAssertEqual(report.fileOutcomes.first?.mediaType, "unknown")
        XCTAssertEqual(report.fileOutcomes.first?.outcome, "unknown")
        XCTAssertEqual(report.fileOutcomes.first?.path, "unknown")
        XCTAssertEqual(report.fileOutcomes.first?.finalPath, "unknown")
        XCTAssertEqual(report.fileOutcomes.first?.executed, false)
    }

    private func makeInput(
        summary: [String: Any] = [:],
        finalStatus: String = "completed",
        dryRun: Bool = false,
        verificationEnabled: Bool = true,
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
            verificationEnabled: verificationEnabled,
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
