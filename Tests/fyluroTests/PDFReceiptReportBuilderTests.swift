import Foundation
import XCTest
@testable import FyluroCore

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
        XCTAssertTrue(report.notices.contains { $0.contains("Dry run") })
        XCTAssertFalse(report.alerts.contains { $0.contains("Dry run") }, "a dry run is information, not a problem")

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
        XCTAssertEqual(
            builder.readablePathScheme(
                "YYYY/<Camera>/<Photos|Videos>/<filename> ; _unsorted/<Camera>/<Photos|Videos>/<filename>",
                includeUnsorted: false
            ).map(\.1),
            ["Year › Camera › Photos/Videos"]
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

    func testRenamedListShowsCardPathToLibraryRelativePath() throws {
        let report = builder.build(input: makeInput(summary: [
            "per_file_outcomes": [
                [
                    "media_type": "photo",
                    "outcome": "committed",
                    "executed": true,
                    "path": "DCIM/100/IMG_0001.JPG",
                    "source_path": "/source/DCIM/100/IMG_0001.JPG",
                    "final_path": "/dest/2023/202311/canon/Photos/IMG_0001-1.JPG",
                    "collision_suffix": "-1",
                ],
            ],
        ]))

        XCTAssertEqual(report.renamedTotal, 1)
        let item = try XCTUnwrap(report.renamed.first)
        XCTAssertEqual(item.sourcePath, "DCIM/100/IMG_0001.JPG")
        XCTAssertEqual(item.finalPath, "2023/202311/canon/Photos/IMG_0001-1.JPG")
    }

    func testExceptionListsAreCappedAndCountTheRest() {
        var outcomes: [[String: Any]] = []
        for index in 0..<250 {
            outcomes.append([
                "media_type": "photo",
                "outcome": "committed",
                "executed": true,
                "path": "DCIM/IMG_\(index).JPG",
                "final_path": "/dest/2023/202311/cam-\(index)/Photos/IMG_\(index)-1.JPG",
                "collision_suffix": "-1",
            ])
        }
        let report = builder.build(input: makeInput(summary: ["per_file_outcomes": outcomes]))

        XCTAssertEqual(report.renamedTotal, 250)
        XCTAssertEqual(report.renamed.count, PDFReceiptReportBuilder.renamedCap)
        XCTAssertEqual(report.landedFolderTotal, 250)
        XCTAssertEqual(report.landed.count, PDFReceiptReportBuilder.landedFolderCap)

        let failed = builder.build(input: makeInput(
            summary: ["per_file_outcomes": outcomes.map { entry in
                var copy = entry
                copy["outcome"] = "stage_and_commit"
                return copy
            }],
            finalStatus: "aborted",
            failurePhase: "commit"
        ))
        XCTAssertEqual(failed.needsLookTotal, 250)
        XCTAssertEqual(failed.needsLook.count, PDFReceiptReportBuilder.needsLookCap)
    }

    func testLateErrorsAreNotHiddenByAnEarlyCap() {
        // The old appendix printed the first 80 files only. A late failure never showed.
        var outcomes: [[String: Any]] = (0..<500).map { index in
            [
                "media_type": "photo", "outcome": "committed", "executed": true,
                "path": "DCIM/IMG_\(index).JPG", "final_path": "/dest/2023/202311/canon/Photos/IMG_\(index).JPG",
            ]
        }
        outcomes.append([
            "media_type": "photo", "outcome": "stage_and_commit", "executed": false,
            "path": "DCIM/LAST.JPG", "final_path": "/dest/2023/202311/canon/Photos/LAST.JPG",
        ])
        let report = builder.build(input: makeInput(
            summary: ["per_file_outcomes": outcomes],
            finalStatus: "aborted",
            failurePhase: "commit"
        ))

        XCTAssertEqual(report.needsLook.map(\.path), ["DCIM/LAST.JPG"])
        XCTAssertEqual(report.needsLook.first?.label, "Not completed")
        XCTAssertEqual(report.needsLook.first?.note, "planned for 2023/202311/canon/Photos/LAST.JPG")
    }

    func testNeedsLookHoldsScanErrorsAndSkipsDryRunPlans() {
        let scan = ScanSummary(
            candidates: [],
            photoCount: 0,
            videoCount: 0,
            photoBytes: 0,
            videoBytes: 0,
            filesInTypicalLocations: 0,
            filesOutsideTypicalLocations: 0,
            errors: (0..<30).map { ScanErrorRecord(path: "/source/BAD_\($0).JPG", message: "unreadable") }
        )
        let plan: [[String: Any]] = [[
            "media_type": "photo", "outcome": "stage_and_commit", "executed": false,
            "path": "A.JPG", "final_path": "/dest/2023/202311/canon/Photos/A.JPG",
        ]]

        let dryRun = builder.build(input: makeInput(summary: ["per_file_outcomes": plan], dryRun: true, scanSummary: scan))
        XCTAssertEqual(dryRun.needsLookTotal, 30)
        XCTAssertTrue(dryRun.needsLook.allSatisfy { $0.label == "Scan error" })
        XCTAssertEqual(dryRun.needsLook.first?.note, "unreadable")
    }

    func testDuplicatesAreCountedNeverListed() {
        let report = builder.build(input: makeInput(summary: reviewedRunSummary()))

        XCTAssertEqual(report.alreadyInLibraryCount, 41)
        XCTAssertEqual(report.needsLookTotal, 0)
        XCTAssertEqual(report.landed.map(\.total), [9])
        XCTAssertEqual(report.landed.first?.folder, "2023/202311/canon/Photos")
        XCTAssertEqual(report.landed.first?.sidecars, 9)
        XCTAssertEqual(report.landed.first?.photos, 0)
    }

    func testDryRunLandedTableListsFilesThatWouldBeAdded() {
        let report = builder.build(input: makeInput(summary: reviewedRunSummary(), dryRun: true))
        XCTAssertEqual(report.landed.map(\.total), [9])
    }

    func testUnknownFallbacksWhenSummaryFieldsMissingOrInvalid() {
        let report = builder.build(input: makeInput(summary: [
            "date_range": ["start": "unknown", "end": "unknown"],
            "camera_labels": [["label": NSNull(), "file_count": "abc"]],
            "per_file_outcomes": [["executed": NSNull()]],
        ]))
        XCTAssertEqual(report.needsLook.first?.path, "unknown")
        XCTAssertEqual(report.foundCount, 1)

        XCTAssertEqual(value(for: "Path scheme", in: report.contextRows), "unknown")
        XCTAssertEqual(report.cameraDistribution.first, "unknown: 0")
    }

    private func reviewedRunSummary() -> [String: Any] {
        var outcomes: [[String: Any]] = (0..<41).map { index in
            [
                "media_type": "photo",
                "outcome": "duplicate_not_copied",
                "executed": true,
                "path": "DCIM/IMG_\(index).JPG",
                "final_path": "/dest/2023/202311/canon/Photos/IMG_\(index).JPG",
            ]
        }
        for index in 0..<9 {
            var entry: [String: Any] = [
                "media_type": "photo",
                "outcome": "committed",
                "executed": true,
                "path": "DCIM/IMG_\(index).XMP",
                "final_path": "/dest/2023/202311/canon/Photos/IMG_\(index)-1.XMP",
            ]
            if index < 6 { entry["collision_suffix"] = "-1" }
            outcomes.append(entry)
        }
        return [
            "totals_by_outcome": [
                "copied": 50, "verified": 50, "committed": 9,
                "duplicate_not_copied": 41, "conflicts_renamed": 6, "errors": 0,
            ],
            "per_file_outcomes": outcomes,
        ]
    }

    func testMetricsForReviewedRunAddUp() throws {
        let report = builder.build(input: makeInput(summary: reviewedRunSummary()))

        let found = try XCTUnwrap(metric("Found", in: report))
        XCTAssertEqual(found.value, "50")
        XCTAssertEqual(found.subtitle, "41 media + 9 sidecars")
        XCTAssertEqual(metric("Verified", in: report)?.value, "50")
        XCTAssertEqual(metric("Added to library", in: report)?.value, "9")
        XCTAssertEqual(metric("Already in library", in: report)?.value, "41")
        XCTAssertEqual(metric("Renamed", in: report)?.value, "6")
        XCTAssertNil(metric("Copied", in: report))
        XCTAssertNil(metric("Candidates", in: report))

        let foundCount = try XCTUnwrap(Int(found.value))
        let added = try XCTUnwrap(Int(try XCTUnwrap(metric("Added to library", in: report)).value))
        let already = try XCTUnwrap(Int(try XCTUnwrap(metric("Already in library", in: report)).value))
        XCTAssertEqual(foundCount, added + already)
    }

    func testToneMappingKeepsAmberOutOfHarmlessFacts() {
        let report = builder.build(input: makeInput(summary: reviewedRunSummary()))
        XCTAssertEqual(metric("Added to library", in: report)?.tone, .success)
        XCTAssertEqual(metric("Already in library", in: report)?.tone, .neutral)
        XCTAssertEqual(metric("Renamed", in: report)?.tone, .neutral)
        XCTAssertEqual(metric("Errors", in: report)?.tone, .success)
        XCTAssertFalse(report.metrics.contains { $0.tone == .warning })

        let withErrors = builder.build(input: makeInput(summary: ["totals_by_outcome": ["errors": 2]]))
        XCTAssertEqual(metric("Errors", in: withErrors)?.tone, .danger)
    }

    func testDryRunShowsWhatWouldHappen() {
        var summary = reviewedRunSummary()
        summary["totals_by_outcome"] = [
            "copied": 0, "verified": 0, "committed": 0, "duplicate_not_copied": 41, "conflicts_renamed": 6, "errors": 0,
        ]
        let report = builder.build(input: makeInput(summary: summary, dryRun: true))

        XCTAssertEqual(metric("Found", in: report)?.value, "50")
        XCTAssertEqual(metric("Verified", in: report)?.value, "Not run")
        XCTAssertEqual(metric("Would add", in: report)?.value, "9")
        XCTAssertEqual(metric("Already in library", in: report)?.value, "41")
        XCTAssertEqual(metric("Would rename", in: report)?.value, "6")
        XCTAssertNil(metric("Added to library", in: report))
    }

    func testFailedRunMarksCommitDependentCountsAsNotCompleted() {
        var summary = reviewedRunSummary()
        summary["totals_by_outcome"] = [
            "copied": 50, "verified": 12, "committed": 0, "duplicate_not_copied": 0, "conflicts_renamed": 0, "errors": 1,
        ]
        let report = builder.build(input: makeInput(summary: summary, finalStatus: "aborted", failurePhase: "verify"))

        XCTAssertEqual(metric("Found", in: report)?.value, "50")
        XCTAssertEqual(metric("Verified", in: report)?.value, "12")
        XCTAssertEqual(metric("Added to library", in: report)?.value, "0")
        XCTAssertEqual(metric("Already in library", in: report)?.value, "—")
        XCTAssertEqual(metric("Already in library", in: report)?.subtitle, "not completed")
        XCTAssertEqual(metric("Renamed", in: report)?.value, "—")
        XCTAssertEqual(metric("Errors", in: report)?.tone, .danger)
    }

    func testFoundFallsBackToScanCountWhenNoOutcomesExist() {
        let candidate = MediaCandidate(
            absolutePath: "/source/A.JPG",
            relativePath: "A.JPG",
            mediaType: .photo,
            sizeBytes: 1,
            mtime: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let scan = ScanSummary(
            candidates: [candidate],
            photoCount: 1,
            videoCount: 0,
            photoBytes: 1,
            videoBytes: 0,
            filesInTypicalLocations: 1,
            filesOutsideTypicalLocations: 0,
            errors: []
        )
        let report = builder.build(input: makeInput(finalStatus: "aborted", failurePhase: "scan", scanSummary: scan))
        XCTAssertEqual(metric("Found", in: report)?.value, "1")
    }

    func testSidecarClassificationFollowsExtensionAndWavRule() {
        let report = builder.build(input: makeInput(summary: [
            "per_file_outcomes": [
                ["media_type": "photo", "outcome": "committed", "path": "DCIM/IMG_0001.JPG", "final_path": "/dest/d/IMG_0001.JPG"],
                ["media_type": "photo", "outcome": "committed", "path": "DCIM/IMG_0001.XMP", "final_path": "/dest/d/IMG_0001.XMP"],
                ["media_type": "video", "outcome": "committed", "path": "DCIM/CLIP_0012.MP4", "final_path": "/dest/d/CLIP_0012.MP4"],
                ["media_type": "video", "outcome": "committed", "path": "DCIM/CLIP_0012.WAV", "final_path": "/dest/d/CLIP_0012.WAV"],
                ["media_type": "audio", "outcome": "committed", "path": "AUDIO/REC_0001.WAV", "final_path": "/dest/d/REC_0001.WAV"],
                ["media_type": "video", "outcome": "committed", "path": "DCIM/CLIP_0012.THM", "final_path": "/dest/d/CLIP_0012.THM"],
            ],
        ]))

        XCTAssertEqual(metric("Found", in: report)?.subtitle, "3 media + 3 sidecars")
        let folder = report.landed.first
        XCTAssertEqual(folder?.photos, 1)
        XCTAssertEqual(folder?.videos, 1)
        XCTAssertEqual(folder?.audio, 1)
        XCTAssertEqual(folder?.sidecars, 3)
    }

    func testSameDayDateRangeIsShortened() throws {
        let sameDay = builder.build(input: makeInput(summary: [
            "date_range": ["start": "2026-09-23T17:49:00Z", "end": "2026-09-23T19:23:00Z"],
        ]))
        let range = try XCTUnwrap(value(for: "Date range", in: sameDay.inventoryRows))
        XCTAssertFalse(range.contains(" to "))
        XCTAssertTrue(range.contains("–"))

        let multiDay = builder.build(input: makeInput(summary: [
            "date_range": ["start": "2023-08-11T08:15:52Z", "end": "2026-07-16T07:48:57Z"],
        ]))
        XCTAssertTrue(try XCTUnwrap(value(for: "Date range", in: multiDay.inventoryRows)).contains(" to "))

        let unknown = builder.build(input: makeInput(summary: ["date_range": ["start": "unknown", "end": "unknown"]]))
        XCTAssertEqual(value(for: "Date range", in: unknown.inventoryRows), "unknown")
    }

    private func metric(_ label: String, in report: PDFReceiptReport) -> PDFReceiptReport.Metric? {
        report.metrics.first { $0.label == label }
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
