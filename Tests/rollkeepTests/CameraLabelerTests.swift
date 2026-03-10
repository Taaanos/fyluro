import Foundation
import XCTest
@testable import RollKeepCore

final class CameraLabelerTests: XCTestCase {
    func testInferBuildsFolderSafeStableLabelFromModelAndSerial() {
        let candidate = MediaCandidate(
            absolutePath: "/source/DCIM/100/IMG_0001.JPG",
            relativePath: "DCIM/100/IMG_0001.JPG",
            mediaType: .photo,
            sizeBytes: 42,
            mtime: Date(timeIntervalSince1970: 1_700_000_000),
            photoMetadata: PhotoMetadata(
                captureDateTime: Date(timeIntervalSince1970: 1_700_000_100),
                captureDateSource: .dateTimeOriginal,
                cameraMake: "Sony",
                cameraModel: "A7 IV / a7 IV",
                cameraSerial: "12345678"
            )
        )

        let inferred = CameraLabeler().infer(for: candidate)
        XCTAssertEqual(inferred.cameraLabel, "a7-iv-a7-iv-sn-12345678")
    }

    func testAssessCardFlagsMixedCameraAndUsesSafeMixedLabel() {
        let firstCameraFiles = (0..<6).map { index in
            MediaCandidate(
                absolutePath: "/source/DCIM/A/IMG_A_\(index).JPG",
                relativePath: "DCIM/A/IMG_A_\(index).JPG",
                mediaType: .photo,
                sizeBytes: 10,
                mtime: Date(timeIntervalSince1970: 1_700_000_000 + Double(index)),
                photoMetadata: PhotoMetadata(
                    captureDateTime: Date(timeIntervalSince1970: 1_700_000_010 + Double(index)),
                    captureDateSource: .dateTimeOriginal,
                    cameraMake: "Canon",
                    cameraModel: "EOS R5",
                    cameraSerial: "11110000"
                )
            )
        }

        let secondCameraFiles = (0..<4).map { index in
            MediaCandidate(
                absolutePath: "/source/DCIM/B/IMG_B_\(index).JPG",
                relativePath: "DCIM/B/IMG_B_\(index).JPG",
                mediaType: .photo,
                sizeBytes: 10,
                mtime: Date(timeIntervalSince1970: 1_700_000_100 + Double(index)),
                photoMetadata: PhotoMetadata(
                    captureDateTime: Date(timeIntervalSince1970: 1_700_000_110 + Double(index)),
                    captureDateSource: .dateTimeOriginal,
                    cameraMake: "Fujifilm",
                    cameraModel: "X100V",
                    cameraSerial: "22220000"
                )
            )
        }

        let assessment = CameraLabeler().assessCard(candidates: firstCameraFiles + secondCameraFiles)

        XCTAssertTrue(assessment.mixedCameraDetected)
        XCTAssertEqual(assessment.cameraLabel, "mixed-camera")
        XCTAssertEqual(assessment.totalCandidates, 10)
        XCTAssertEqual(assessment.knownCameraFileCount, 10)
        XCTAssertEqual(assessment.unknownCameraFileCount, 0)
        XCTAssertEqual(assessment.distribution.map(\.cameraLabel), ["eos-r5-sn-11110000", "x100v-sn-22220000"])
        XCTAssertEqual(assessment.distribution.map(\.fileCount), [6, 4])
    }

    func testAssessCardInventoriesAllCandidates() {
        let candidates = (0..<31).map { index in
            MediaCandidate(
                absolutePath: "/source/DCIM/A/IMG_\(index).JPG",
                relativePath: "DCIM/A/IMG_\(index).JPG",
                mediaType: .photo,
                sizeBytes: 10,
                mtime: Date(timeIntervalSince1970: 1_700_000_000 + Double(index)),
                photoMetadata: PhotoMetadata(
                    captureDateTime: Date(timeIntervalSince1970: 1_700_000_010 + Double(index)),
                    captureDateSource: .dateTimeOriginal,
                    cameraMake: "Canon",
                    cameraModel: "EOS R5",
                    cameraSerial: "11110000"
                )
            )
        }

        let assessment = CameraLabeler().assessCard(candidates: candidates)

        XCTAssertFalse(assessment.mixedCameraDetected)
        XCTAssertEqual(assessment.cameraLabel, "eos-r5-sn-11110000")
        XCTAssertEqual(assessment.totalCandidates, 31)
        XCTAssertEqual(assessment.knownCameraFileCount, 31)
        XCTAssertEqual(assessment.unknownCameraFileCount, 0)
        XCTAssertEqual(assessment.distribution.map(\.fileCount), [31])
    }
}
