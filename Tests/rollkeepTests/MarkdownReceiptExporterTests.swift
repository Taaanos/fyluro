import Foundation
import XCTest
@testable import RollKeepCore
@testable import rollkeep

final class PDFReceiptExporterTests: XCTestCase {
    func testBuildReportLinesIncludesContextAndInventorySections() {
        let datedPhoto = MediaCandidate(
            absolutePath: "/source/DCIM/100/IMG_0001.JPG",
            relativePath: "DCIM/100/IMG_0001.JPG",
            mediaType: .photo,
            sizeBytes: 10,
            mtime: Date(timeIntervalSince1970: 1_700_000_000),
            photoMetadata: PhotoMetadata(
                captureDateTime: Date(timeIntervalSince1970: 1_700_000_100),
                captureDateSource: .dateTimeOriginal,
                cameraMake: "Canon",
                cameraModel: "EOS R5",
                cameraSerial: "ABC123"
            )
        )

        let summary = ScanSummary(
            candidates: [datedPhoto],
            photoCount: 1,
            videoCount: 0,
            photoBytes: 10,
            videoBytes: 0,
            filesInTypicalLocations: 1,
            filesOutsideTypicalLocations: 0,
            errors: []
        )

        let summaryData: [String: Any] = [
            "totals_by_outcome": [
                "copied": 1,
                "verified": 1,
                "committed": 1,
                "duplicate_not_copied": 0,
                "conflicts_renamed": 0,
                "errors": 0,
            ],
            "totals_by_media_type": [
                "photos": 1,
                "videos": 0,
            ],
            "phase_timings_ms": [
                ["phase": "scan", "milliseconds": 120],
                ["phase": "plan", "milliseconds": 80],
            ],
            "path_scheme": "YYYY/YYYYMM/<Camera>/<Photos|Videos>/<filename> ; _unsorted/<Camera>/<Photos|Videos>/<filename>",
            "camera_label": "canon-eos-r5",
            "mixed_camera_detected": false,
            "known_camera_file_count": 1,
            "unknown_camera_file_count": 0,
            "camera_labels": [
                ["label": "canon-eos-r5", "file_count": 1],
            ],
            "date_range": [
                "start": "2023-11-14T22:15:00Z",
                "end": "2023-11-14T22:15:00Z",
            ],
            "per_file_outcomes": [
                [
                    "path": "DCIM/100/IMG_0001.JPG",
                    "media_type": "photo",
                    "outcome": "stage_and_commit",
                    "executed": true,
                    "final_path": "/dest/2023/202311/canon-eos-r5/Photos/IMG_0001.JPG",
                ],
            ],
        ]

        let lines = PDFReceiptExporter().buildReportLines(
            sessionID: "session-123",
            sourcePath: "/source",
            destinationPath: "/dest",
            dryRun: false,
            receiptSink: ReceiptSink(kind: .destination, path: "/dest/_ingest_receipts/session-123.ndjson"),
            generatedAt: Date(timeIntervalSince1970: 1_700_001_000),
            finalStatus: "completed",
            failurePhase: nil,
            failureReason: nil,
            summary: summaryData,
            scanSummary: summary
        )

        let report = lines.joined(separator: "\n")
        XCTAssertTrue(report.contains("RollKeep Transfer Receipt"))
        XCTAssertTrue(report.contains("Status: VERIFIED"))
        XCTAssertTrue(report.contains("At a glance"))
        XCTAssertTrue(report.contains("Run context"))
        XCTAssertTrue(report.contains("Capture inventory"))
        XCTAssertTrue(report.contains("Committed: 1"))
        XCTAssertTrue(report.contains("Path Scheme: YYYY/YYYYMM/<Camera>/<Photos|Videos>/<filename> ; _unsorted/<Camera>/<Photos|Videos>/<filename>"))
        XCTAssertTrue(report.contains("Card label: canon-eos-r5"))
        XCTAssertTrue(report.contains("File appendix"))
        XCTAssertTrue(report.contains("DCIM/100/IMG_0001.JPG"))
    }

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
            "camera_label": "unknown-camera",
            "mixed_camera_detected": false,
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
}
