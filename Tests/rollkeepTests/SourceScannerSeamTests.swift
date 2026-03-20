import Foundation
import XCTest
@testable import RollKeepCore

final class SourceScannerSeamTests: XCTestCase {
    func testTraversalNormalizeRelativePathRejectsBoundaryViolations() {
        let traversal = SourceScannerTraversal(unknownLargeFileWarningThresholdBytes: 0)
        let rootURL = URL(fileURLWithPath: "/tmp/rollkeep-root", isDirectory: true)
        let outsiderURL = URL(fileURLWithPath: "/tmp/elsewhere/clip.MP4", isDirectory: false)

        XCTAssertThrowsError(
            try traversal.normalizeRelativePath(
                url: outsiderURL,
                canonicalSourceRootURL: rootURL,
                sourceRootComponents: rootURL.pathComponents
            )
        ) { error in
            guard case .sourceBoundaryViolation(let path, let sourceRoot) = error as? SourceScannerError else {
                XCTFail("Unexpected error: \(error)")
                return
            }
            XCTAssertEqual(path, outsiderURL.path)
            XCTAssertEqual(sourceRoot, rootURL.path)
        }
    }

    func testTraversalUnknownLargeWarningDedupesByPath() {
        let traversal = SourceScannerTraversal(unknownLargeFileWarningThresholdBytes: 1_024)
        var warnings: [ScanWarningRecord] = []

        traversal.maybeRecordUnknownLargeSkippedFileWarning(
            relativePath: "PRIVATE/CLIP_0001.MYSTERY",
            fileSize: 2_048,
            warnings: &warnings
        )
        traversal.maybeRecordUnknownLargeSkippedFileWarning(
            relativePath: "PRIVATE/CLIP_0001.MYSTERY",
            fileSize: 2_048,
            warnings: &warnings
        )

        XCTAssertEqual(warnings.count, 1)
        XCTAssertEqual(warnings.first?.fileExtension, "mystery")
    }

    func testMetadataResolverForcedMissingCaptureDateClearsPhotoAndVideoMetadata() {
        let resolver = SourceScannerMetadataResolver(
            photoMetadataExtractor: SeamPhotoMetadataExtractor(),
            videoMetadataExtractor: SeamVideoMetadataExtractor(),
            previewVideoMetadataExtractor: SeamVideoMetadataExtractor(),
            forcedMissingCaptureDateRelativePaths: [
                "DCIM/100MEDIA/IMG_FORCE.JPG",
                "PRIVATE/FORCE.MP4",
            ]
        )

        let mtime = Date(timeIntervalSince1970: 1_704_300_000)
        let photoResult = resolver.resolve(
            mediaType: .photo,
            fileURL: URL(fileURLWithPath: "/tmp/IMG_FORCE.JPG"),
            relativePath: "DCIM/100MEDIA/IMG_FORCE.JPG",
            fallbackMtime: mtime,
            mode: .deep
        )
        let videoResult = resolver.resolve(
            mediaType: .video,
            fileURL: URL(fileURLWithPath: "/tmp/FORCE.MP4"),
            relativePath: "PRIVATE/FORCE.MP4",
            fallbackMtime: mtime,
            mode: .deep
        )

        XCTAssertNil(photoResult.photoMetadata?.captureDateTime)
        XCTAssertEqual(photoResult.photoMetadata?.captureDateSource, .missing)
        XCTAssertNil(videoResult.videoMetadata)
    }

    func testProgressSnapshotCalculatorBuildsAssessmentFromCameraDistribution() {
        let calculator = SourceScannerProgressSnapshotCalculator()
        let snapshot = calculator.makeProgressSnapshot(
            itemCount: 3,
            filesChecked: 9,
            photoCount: 2,
            videoCount: 1,
            photoBytes: 22,
            videoBytes: 33,
            bytesChecked: 120,
            totalBytes: 55,
            currentRelativePath: "DCIM/100MEDIA/IMG_0001.JPG",
            cameraLabelCounts: [
                "sony-fx3": 2,
                CameraLabeler.unknownLabel: 1,
            ]
        )

        XCTAssertEqual(snapshot.cameraAssessment.cameraLabel, "sony-fx3")
        XCTAssertFalse(snapshot.cameraAssessment.mixedCameraDetected)
        XCTAssertEqual(snapshot.cameraAssessment.knownCameraFileCount, 2)
        XCTAssertEqual(snapshot.cameraAssessment.unknownCameraFileCount, 1)
    }
}

private struct SeamPhotoMetadataExtractor: PhotoMetadataExtracting {
    func extract(from fileURL: URL) -> PhotoMetadata {
        PhotoMetadata(
            captureDateTime: Date(timeIntervalSince1970: 1_700_000_000),
            captureDateSource: .dateTimeOriginal,
            cameraMake: "Canon",
            cameraModel: "EOS R5",
            cameraSerial: "1234"
        )
    }
}

private struct SeamVideoMetadataExtractor: VideoMetadataExtracting {
    func extract(from fileURL: URL, fallbackMtime: Date) -> VideoMetadata {
        VideoMetadata(
            captureDateTime: fallbackMtime.addingTimeInterval(10),
            captureDateSource: .creationTime,
            usedFallback: false,
            cameraMake: "Sony",
            cameraModel: "FX3",
            cameraSerial: "5678"
        )
    }
}
