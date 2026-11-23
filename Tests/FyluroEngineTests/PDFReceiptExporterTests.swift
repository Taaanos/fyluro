import Foundation
import PDFKit
import XCTest
@testable import FyluroCore
@testable import FyluroEngine

final class PDFReceiptExporterTests: XCTestCase {
    func testWriteProducesPDFFile() throws {
        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("fyluro-pdf-receipt-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let receiptPath = tempRoot
            .appendingPathComponent("_ingest_receipts", isDirectory: true)
            .appendingPathComponent("session-123.ndjson", isDirectory: false)
            .path

        let summary = ScanSummary(
            candidates: [],
            photoCount: 0,
            videoCount: 0,
            photoBytes: 0,
            videoBytes: 0,
            filesInTypicalLocations: 0,
            filesOutsideTypicalLocations: 0,
            errors: []
        )

        let summaryData: [String: Any] = [
            "totals_by_outcome": ["copied": 0, "verified": 0, "committed": 0, "duplicate_not_copied": 0, "conflicts_renamed": 0, "errors": 0],
            "totals_by_media_type": ["photos": 0, "videos": 0],
            "phase_timings_ms": [],
            "path_scheme": "YYYY/YYYYMM/<Camera>/<Photos|Videos>/<filename> ; _unsorted/<Camera>/<Photos|Videos>/<filename>",
            "known_camera_file_count": 0,
            "unknown_camera_file_count": 0,
            "camera_labels": [],
            "date_range": ["start": "unknown", "end": "unknown"],
            "per_file_outcomes": [],
        ]

        let url = try PDFReceiptExporter().write(
            sessionID: "session-123",
            sourcePath: "/source",
            destinationPath: "/dest",
            dryRun: true,
            receiptSink: ReceiptSink(kind: .destination, path: receiptPath),
            generatedAt: Date(),
            finalStatus: "completed",
            failurePhase: nil,
            failureReason: nil,
            summary: summaryData,
            scanSummary: summary
        )

        XCTAssertEqual(url.pathExtension, "pdf")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertGreaterThan((attributes[.size] as? NSNumber)?.intValue ?? 0, 0)
    }

    func testFooterShowsShortSessionAndPageNumberOnEveryPage() throws {
        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("fyluro-pdf-footer-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let sessionID = "0A1B2C3D-4E5F-6789-ABCD-EF0123456789"
        let outcomes: [[String: Any]] = (0..<120).map { index in
            [
                "path": "DCIM/100/IMG_\(index).JPG",
                "source_path": "/source/DCIM/100/IMG_\(index).JPG",
                "media_type": "photo",
                "outcome": "committed",
                "executed": true,
                "final_path": "/dest/2023/202311/camera-\(index)/Photos/IMG_\(index)-1.JPG",
                "collision_suffix": "-1",
            ]
        }
        let summaryData: [String: Any] = [
            "totals_by_outcome": ["copied": 120, "verified": 120, "committed": 120, "duplicate_not_copied": 0, "conflicts_renamed": 0, "errors": 0],
            "path_scheme": "YYYY/YYYYMM/<Camera>/<Photos|Videos>/<filename> ; _unsorted/<Camera>/<Photos|Videos>/<filename>",
            "per_file_outcomes": outcomes,
        ]
        let scan = ScanSummary(
            candidates: [],
            photoCount: 0,
            videoCount: 0,
            photoBytes: 0,
            videoBytes: 0,
            filesInTypicalLocations: 0,
            filesOutsideTypicalLocations: 0,
            errors: []
        )

        let url = try PDFReceiptExporter().write(
            sessionID: sessionID,
            sourcePath: "/source",
            destinationPath: "/dest",
            dryRun: false,
            receiptSink: ReceiptSink(
                kind: .destination,
                path: tempRoot.appendingPathComponent("_ingest_receipts/\(sessionID).ndjson").path
            ),
            generatedAt: Date(),
            finalStatus: "completed",
            failurePhase: nil,
            failureReason: nil,
            summary: summaryData,
            scanSummary: scan
        )

        let document = try XCTUnwrap(PDFDocument(url: url))
        XCTAssertGreaterThan(document.pageCount, 1)
        for index in 0..<document.pageCount {
            let text = document.page(at: index)?.string ?? ""
            XCTAssertTrue(text.contains("Page \(index + 1)"), "Page \(index + 1) has no page number in its footer")
            XCTAssertTrue(text.contains("Session 0A1B2C3D"))
        }
    }

    func testBigCardPaginatesAndEndsExceptionListsWithAndNMoreLines() throws {
        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("fyluro-pdf-bigcard-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        var outcomes: [[String: Any]] = []
        for index in 0..<2_000 {
            var entry: [String: Any] = [
                "path": "DCIM/\(index / 100)/IMG_\(index).JPG",
                "media_type": "photo",
                "outcome": "committed",
                "executed": true,
                "final_path": "/dest/2023/202311/camera-\(index / 5)/Photos/IMG_\(index)-1.JPG",
            ]
            if index < 300 { entry["collision_suffix"] = "-1" }
            outcomes.append(entry)
        }
        for index in 0..<400 {
            outcomes.append([
                "path": "DCIM/dup/IMG_\(index).JPG",
                "media_type": "photo",
                "outcome": "duplicate_not_copied",
                "executed": true,
                "final_path": "/dest/2022/202201/camera-old/Photos/IMG_\(index).JPG",
            ])
        }
        let summaryData: [String: Any] = [
            "totals_by_outcome": [
                "copied": 2_400, "verified": 2_400, "committed": 2_000,
                "duplicate_not_copied": 400, "conflicts_renamed": 300, "errors": 230,
            ],
            "path_scheme": "YYYY/YYYYMM/<Camera>/<Photos|Videos>/<filename> ; _unsorted/<Camera>/<Photos|Videos>/<filename>",
            "per_file_outcomes": outcomes,
        ]
        let scan = ScanSummary(
            candidates: [],
            photoCount: 2_400,
            videoCount: 0,
            photoBytes: 0,
            videoBytes: 0,
            filesInTypicalLocations: 0,
            filesOutsideTypicalLocations: 0,
            errors: (0..<230).map { ScanErrorRecord(path: "/source/DCIM/BAD_\($0).JPG", message: "Could not read file") }
        )

        let url = try PDFReceiptExporter().write(
            sessionID: "BIG-CARD-0001",
            sourcePath: "/source",
            destinationPath: "/dest",
            dryRun: false,
            receiptSink: ReceiptSink(kind: .destination, path: tempRoot.appendingPathComponent("r.ndjson").path),
            generatedAt: Date(),
            finalStatus: "completed",
            failurePhase: nil,
            failureReason: nil,
            summary: summaryData,
            scanSummary: scan
        )

        let document = try XCTUnwrap(PDFDocument(url: url))
        let text = (0..<document.pageCount).compactMap { document.page(at: $0)?.string }.joined(separator: "\n")
        XCTAssertGreaterThan(document.pageCount, 3)
        XCTAssertTrue(text.contains("Needs a Look"), "needs-a-look heading must use Title Case")
        XCTAssertTrue(text.contains("Renamed to Avoid Overwrite"), "renamed heading must use Title Case")
        XCTAssertTrue(text.contains("Destination Folders"), "destination folders heading must use Title Case")
        XCTAssertTrue(text.contains("and 30 more — see the .ndjson receipt"), "needs-a-look cap line missing")
        XCTAssertTrue(text.contains("and 100 more — see the .ndjson receipt"), "renamed cap line missing")
        XCTAssertTrue(text.contains("and 340 more folders"), "landed folders cap line missing")
        XCTAssertTrue(text.contains("Already in library: 400 files were not copied again"))
        XCTAssertFalse(text.contains("IMG_1999.JPG"), "a duplicate or late file must not be listed one by one")
        for index in 0..<document.pageCount {
            XCTAssertTrue((document.page(at: index)?.string ?? "").contains("Page \(index + 1)"))
        }
    }

    func testDestinationFoldersHeadingStaysAttachedToTableAcrossPageBreak() throws {
        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("fyluro-pdf-landed-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let outcomes: [[String: Any]] = [
            [
                "path": "DCIM/100MSDCF/DSC00001.JPG",
                "media_type": "photo",
                "outcome": "committed",
                "executed": true,
                "final_path": "/Volumes/Jubi/Archive/2026/202611/ilce-7cm2/Photos/Non-RAW/DSC00001.JPG",
            ],
            [
                "path": "DCIM/100MSDCF/DSC00002.ARW",
                "media_type": "photo",
                "outcome": "committed",
                "executed": true,
                "final_path": "/Volumes/Jubi/Archive/2026/202611/ilce-7cm2/Photos/RAW/DSC00002.ARW",
            ],
            [
                "path": "PRIVATE/M4ROOT/CLIP/C0001.MP4",
                "media_type": "video",
                "outcome": "committed",
                "executed": true,
                "final_path": "/Volumes/Jubi/Archive/2026/202611/ilce-7cm2/Videos/C0001.MP4",
            ],
        ]
        let summaryData: [String: Any] = [
            "totals_by_outcome": ["copied": 3, "verified": 3, "committed": 3, "duplicate_not_copied": 0, "conflicts_renamed": 0, "errors": 0],
            "totals_by_media_type": ["photos": 2, "videos": 1],
            "path_scheme": "YYYY/YYYYMM/<Camera>/<Photos|Videos>/<filename>",
            "known_camera_file_count": 3,
            "unknown_camera_file_count": 0,
            "camera_labels": ["ilce-7cm2": 3],
            "date_range": ["start": "2026-11-22T11:36:24Z", "end": "2026-11-23T19:51:06Z"],
            "per_file_outcomes": outcomes,
        ]
        let scan = ScanSummary(
            candidates: [],
            photoCount: 2,
            videoCount: 1,
            photoBytes: 1_000,
            videoBytes: 2_000,
            filesInTypicalLocations: 3,
            filesOutsideTypicalLocations: 0,
            errors: []
        )

        let url = try PDFReceiptExporter().write(
            sessionID: "c2fc2705-5888-4bab-b698-db3f24a623e5",
            sourcePath: "/Volumes/Untitled",
            destinationPath: "/Volumes/Jubi/Archive",
            dryRun: false,
            receiptSink: ReceiptSink(kind: .destination, path: tempRoot.appendingPathComponent("receipt.ndjson").path),
            generatedAt: Date(),
            finalStatus: "completed",
            failurePhase: nil,
            failureReason: nil,
            summary: summaryData,
            scanSummary: scan
        )

        let document = try XCTUnwrap(PDFDocument(url: url))
        let pageTexts = (0..<document.pageCount).map { document.page(at: $0)?.string ?? "" }
        let headingPageIndex = pageTexts.firstIndex { $0.contains("Destination Folders") }
        let tablePageIndex = pageTexts.firstIndex { $0.contains("2026/202611/ilce-7cm2/Photos/RAW") }
        XCTAssertNotNil(headingPageIndex)
        XCTAssertEqual(headingPageIndex, tablePageIndex)

        let dryRunURL = try PDFReceiptExporter().write(
            sessionID: "c2fc2705-5888-4bab-b698-db3f24a623e6",
            sourcePath: "/Volumes/Untitled",
            destinationPath: "/Volumes/Jubi/Archive",
            dryRun: true,
            receiptSink: ReceiptSink(kind: .destination, path: tempRoot.appendingPathComponent("dry-run.ndjson").path),
            generatedAt: Date(),
            finalStatus: "completed",
            failurePhase: nil,
            failureReason: nil,
            summary: summaryData,
            scanSummary: scan
        )
        let dryRunDoc = try XCTUnwrap(PDFDocument(url: dryRunURL))
        let dryRunText = (0..<dryRunDoc.pageCount).compactMap { dryRunDoc.page(at: $0)?.string }.joined(separator: "\n")
        XCTAssertTrue(dryRunText.contains("Planned Destination Folders"))
    }

    func testMetricCardRectsFillUsableWidthOnPartialLastRow() {
        let originX: CGFloat = 48
        let usableWidth: CGFloat = 516
        let gap: CGFloat = 12
        let rects = PDFReceiptPageComposer.metricCardRects(
            count: 7,
            maxPerRow: 4,
            originX: originX,
            topY: 600,
            usableWidth: usableWidth,
            cardHeight: 80,
            gap: gap
        )

        XCTAssertEqual(rects.count, 7)
        // Row 0 has 4 cards spanning the full usable width.
        XCTAssertEqual(rects[0].minX, originX, accuracy: 0.01)
        XCTAssertEqual(rects[3].maxX, originX + usableWidth, accuracy: 0.01)
        // Row 1 has 3 cards spanning the full usable width without a trailing gap.
        XCTAssertEqual(rects[4].minX, originX, accuracy: 0.01)
        XCTAssertEqual(rects[6].maxX, originX + usableWidth, accuracy: 0.01)
        XCTAssertEqual(rects[4].width, rects[5].width, accuracy: 0.01)
        XCTAssertEqual(rects[5].width, rects[6].width, accuracy: 0.01)
        XCTAssertEqual(rects[4].maxY + gap, rects[0].minY, accuracy: 0.01)
    }
}
