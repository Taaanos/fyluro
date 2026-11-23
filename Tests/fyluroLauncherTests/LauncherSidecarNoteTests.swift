import Foundation
import XCTest
import FyluroCore
@testable import fyluroLauncher

final class LauncherSidecarNoteTests: XCTestCase {
    func testSidecarNoteFormattingHandlesZeroSingularAndPlural() {
        XCTAssertNil(LauncherSourceScopeSummary.sidecarNoteText(for: 0))
        XCTAssertNil(LauncherSourceScopeSummary.sidecarNoteText(for: -2))
        XCTAssertEqual(LauncherSourceScopeSummary.sidecarNoteText(for: 1), "+ 1 sidecar")
        XCTAssertEqual(LauncherSourceScopeSummary.sidecarNoteText(for: 11), "+ 11 sidecars")
    }

    func testScanSummaryDeduplicatesSharedSidecarsAcrossCandidates() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let sharedXMP = MediaSidecar(
            absolutePath: "/Volumes/Card/DCIM/IMG_0001.XMP",
            relativePath: "DCIM/IMG_0001.XMP",
            sizeBytes: 512,
            mtime: now,
            creationDate: now,
            fileExtension: "xmp"
        )
        let videoXML = MediaSidecar(
            absolutePath: "/Volumes/Card/PRIVATE/C0001M01.XML",
            relativePath: "PRIVATE/C0001M01.XML",
            sizeBytes: 1024,
            mtime: now,
            creationDate: now,
            fileExtension: "xml"
        )

        let rawPhoto = MediaCandidate(
            absolutePath: "/Volumes/Card/DCIM/IMG_0001.ARW",
            relativePath: "DCIM/IMG_0001.ARW",
            mediaType: .photo,
            sizeBytes: 20_000,
            mtime: now,
            sidecars: [sharedXMP]
        )
        let jpegPhoto = MediaCandidate(
            absolutePath: "/Volumes/Card/DCIM/IMG_0001.JPG",
            relativePath: "DCIM/IMG_0001.JPG",
            mediaType: .photo,
            sizeBytes: 5_000,
            mtime: now,
            sidecars: [sharedXMP]
        )
        let video = MediaCandidate(
            absolutePath: "/Volumes/Card/PRIVATE/C0001.MP4",
            relativePath: "PRIVATE/C0001.MP4",
            mediaType: .video,
            sizeBytes: 100_000,
            mtime: now,
            sidecars: [videoXML]
        )

        let scanSummary = ScanSummary(
            candidates: [rawPhoto, jpegPhoto, video],
            photoCount: 2,
            videoCount: 1,
            audioCount: 0,
            photoBytes: 25_000,
            videoBytes: 100_000,
            audioBytes: 0,
            filesInTypicalLocations: 3,
            filesOutsideTypicalLocations: 0,
            errors: []
        )

        XCTAssertEqual(scanSummary.sidecarCount, 2)

        let launcherSummary = LauncherSourceScopeSummary(summary: scanSummary)
        XCTAssertEqual(launcherSummary.sidecarCount, 2)
        XCTAssertEqual(launcherSummary.sidecarNoteText, "+ 2 sidecars")
    }

    func testScanSummaryWithNoSidecarsProducesNilNote() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let photo = MediaCandidate(
            absolutePath: "/Volumes/Card/DCIM/IMG_0002.JPG",
            relativePath: "DCIM/IMG_0002.JPG",
            mediaType: .photo,
            sizeBytes: 5_000,
            mtime: now,
            sidecars: []
        )
        let scanSummary = ScanSummary(
            candidates: [photo],
            photoCount: 1,
            videoCount: 0,
            audioCount: 0,
            photoBytes: 5_000,
            videoBytes: 0,
            audioBytes: 0,
            filesInTypicalLocations: 1,
            filesOutsideTypicalLocations: 0,
            errors: []
        )

        XCTAssertEqual(scanSummary.sidecarCount, 0)
        XCTAssertNil(LauncherSourceScopeSummary(summary: scanSummary).sidecarNoteText)
    }
}
