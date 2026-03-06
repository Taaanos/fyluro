import Foundation
import XCTest
@testable import rollkeep

final class MarkdownReceiptExporterTests: XCTestCase {
    func testRenderIncludesExifCoverageAndUnsortedSection() {
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

        let unsortedPhoto = MediaCandidate(
            absolutePath: "/source/DCIM/100/IMG_0002.JPG",
            relativePath: "DCIM/100/IMG_0002.JPG",
            mediaType: .photo,
            sizeBytes: 20,
            mtime: Date(timeIntervalSince1970: 1_700_000_200),
            photoMetadata: PhotoMetadata(
                captureDateTime: nil,
                captureDateSource: .missing,
                cameraMake: "Fujifilm",
                cameraModel: "X100V",
                cameraSerial: nil
            )
        )

        let video = MediaCandidate(
            absolutePath: "/source/PRIVATE/clip.MP4",
            relativePath: "PRIVATE/clip.MP4",
            mediaType: .video,
            sizeBytes: 30,
            mtime: Date(timeIntervalSince1970: 1_700_000_300),
            photoMetadata: nil
        )

        let summary = ScanSummary(
            candidates: [datedPhoto, unsortedPhoto, video],
            photoCount: 2,
            videoCount: 1,
            photoBytes: 30,
            videoBytes: 30,
            filesInTypicalLocations: 3,
            filesOutsideTypicalLocations: 0,
            errors: []
        )

        let markdown = MarkdownReceiptExporter().render(
            sessionID: "session-123",
            sourcePath: "/source",
            destinationPath: "/dest",
            dryRun: true,
            receiptSink: ReceiptSink(kind: .destination, path: "/dest/_ingest_receipts/session-123.ndjson"),
            generatedAt: Date(timeIntervalSince1970: 1_700_001_000),
            summary: summary
        )

        XCTAssertTrue(markdown.contains("Dated (EXIF datetime found): `1`"))
        XCTAssertTrue(markdown.contains("`_unsorted` (EXIF datetime missing): `1`"))
        XCTAssertTrue(markdown.contains("`DateTimeOriginal`: `1`"))
        XCTAssertTrue(markdown.contains("`missing`: `1`"))
        XCTAssertTrue(markdown.contains("`unknown-camera`: `1`"))
        XCTAssertTrue(markdown.contains("| `DCIM/100/IMG_0002.JPG` | `Fujifilm` | `X100V` | `missing` |"))
    }
}
