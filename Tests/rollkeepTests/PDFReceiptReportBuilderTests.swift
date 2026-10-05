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

    func testHeaderRowsHoldRunFactsOnce() {
        let report = builder.build(input: makeInput(summary: [
            "path_scheme": "YYYY/YYYYMM/<Camera>/<Photos|Videos>/<filename> ; _unsorted/<Camera>/<Photos|Videos>/<filename>",
        ]))

        XCTAssertEqual(report.contextRows.map(\.0), ["Generated", "Session", "Source", "Destination", "Path scheme"])
        XCTAssertEqual(value(for: "Session", in: report.contextRows), "session-123")
        XCTAssertEqual(value(for: "Path scheme", in: report.contextRows), "Year/YearMonth › Camera › Photos/Videos")
        XCTAssertNil(value(for: "Receipt sink", in: report.contextRows))
        XCTAssertNil(value(for: "Dry run", in: report.contextRows))
    }

    func testPathSchemeIsReadableForEveryLayout() {
        XCTAssertEqual(
            builder.readablePathScheme(
                "YYYY/MM/<Photos|Videos>/<RAW|Non-RAW (Photos)>/<filename> ; _unsorted/<Photos|Videos>/<RAW|Non-RAW (Photos)>/<filename>",
                includeUnsorted: false
            ).map(\.1),
            ["Year/Month › Photos/Videos › RAW/Non-RAW (photos)"]
        )
        XCTAssertEqual(builder.readablePathScheme("something else", includeUnsorted: true).map(\.1), ["something else"])
        XCTAssertFalse(readableSchemeLine("YYYY/YYYYMM/<Camera>/<Photos|Videos>/<filename> ; x").contains("|"))
        XCTAssertFalse(readableSchemeLine("YYYY/YYYYMM/<Camera>/<Photos|Videos>/<filename> ; x").contains("<"))
    }

    func testUnsortedRowAppearsOnlyWhenUndatedFilesExist() {
        let scheme = "YYYY/YYYYMM/<Camera>/<Photos|Videos>/<filename> ; _unsorted/<Camera>/<Photos|Videos>/<filename>"
        let dated = builder.build(input: makeInput(summary: [
            "path_scheme": scheme,
            "per_file_outcomes": [["final_path": "/dest/2023/202311/canon/Photos/A.JPG"]],
        ]))
        XCTAssertNil(value(for: "Undated files", in: dated.contextRows))

        let undated = builder.build(input: makeInput(summary: [
            "path_scheme": scheme,
            "per_file_outcomes": [["final_path": "/dest/_unsorted/canon/Photos/A.JPG"]],
        ]))
        XCTAssertEqual(value(for: "Undated files", in: undated.contextRows), "_unsorted › Camera › Photos/Videos")
    }

    func testFilmModeSectionIsNilWhenNotUsed() {
        XCTAssertNil(builder.build(input: makeInput()).filmMode)
        XCTAssertNil(builder.build(input: makeInput(summary: ["film_mode": ["used": false]])).filmMode)
    }

    func testFilmModeSectionLeadsWithFilmCameraAndListsOptionalFields() throws {
        let report = builder.build(input: makeInput(summary: [
            "film_mode": [
                "used": true,
                "year": 1998,
                "month": 9,
                "camera": "Pentax K1000",
                "film_stock": "Kodak Portra 400",
                "iso": 400,
                "shot_at_iso": 800,
                "lens": "50mm f/2",
                "development_notes": "Pushed one stop",
                "scanner": "Nikon D850 copy stand",
                "creator": "Jane Doe",
                "copyright": "2026 Jane Doe",
                "exif_applied_count": 30,
                "exif_skipped_count": 2,
            ],
        ]))

        let film = try XCTUnwrap(report.filmMode)
        XCTAssertTrue(film.headline.hasPrefix("Shot on Pentax K1000 · Kodak Portra 400 · ISO 400 (shot at 800) · "))
        XCTAssertTrue(film.headline.hasSuffix("1998"))
        XCTAssertEqual(film.detailRows.map(\.0), ["Lens", "Development", "Digitized with", "Creator", "Copyright"])
        XCTAssertEqual(film.exifNote, "EXIF written to 30 files; 2 RAW files kept their original camera metadata.")
    }

    func testFilmModeSectionSkipsMissingOptionalFields() throws {
        let report = builder.build(input: makeInput(summary: [
            "film_mode": [
                "used": true,
                "year": 2001,
                "month": 3,
                "camera": "Leica M6",
                "exif_applied_count": 1,
                "exif_skipped_count": 0,
            ],
        ]))

        let film = try XCTUnwrap(report.filmMode)
        XCTAssertTrue(film.headline.hasPrefix("Shot on Leica M6 · "))
        XCTAssertFalse(film.headline.contains("ISO"))
        XCTAssertTrue(film.detailRows.isEmpty)
        XCTAssertEqual(film.exifNote, "EXIF written to 1 file.")
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

        XCTAssertEqual(value(for: "Path scheme", in: report.contextRows), "unknown")
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

    private func readableSchemeLine(_ raw: String) -> String {
        builder.readablePathScheme(raw, includeUnsorted: false).first?.1 ?? ""
    }

    private func value(for key: String, in rows: [(String, String)]) -> String? {
        rows.first(where: { $0.0 == key })?.1
    }
}
