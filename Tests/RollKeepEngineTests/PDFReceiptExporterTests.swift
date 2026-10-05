import Foundation
import PDFKit
import XCTest
@testable import RollKeepCore
@testable import RollKeepEngine

final class PDFReceiptExporterTests: XCTestCase {
    func testWriteProducesPDFFile() throws {
        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("rollkeep-pdf-receipt-tests-\(UUID().uuidString)", isDirectory: true)
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
            .appendingPathComponent("rollkeep-pdf-footer-tests-\(UUID().uuidString)", isDirectory: true)
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
                "final_path": "/dest/2023/202311/canon/Photos/IMG_\(index).JPG",
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
}
