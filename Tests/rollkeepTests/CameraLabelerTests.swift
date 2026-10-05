import Foundation
import XCTest
@testable import RollKeepCore

final class CameraLabelerTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        CameraCatalogTestIsolation.useEmptyCatalog()
    }

    func testInferBuildsFolderSafeStableLabelFromModelWithoutSerialSuffix() {
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
        XCTAssertEqual(inferred.cameraLabel, "a7-iv-a7-iv")
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

        XCTAssertEqual(assessment.totalCandidates, 10)
        XCTAssertEqual(assessment.knownCameraFileCount, 10)
        XCTAssertEqual(assessment.unknownCameraFileCount, 0)
        XCTAssertEqual(assessment.distribution.map(\.cameraLabel), ["eos-r5", "x100v"])
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

        XCTAssertEqual(assessment.totalCandidates, 31)
        XCTAssertEqual(assessment.knownCameraFileCount, 31)
        XCTAssertEqual(assessment.unknownCameraFileCount, 0)
        XCTAssertEqual(assessment.distribution.map(\.fileCount), [31])
    }

    func testInferNormalizesIPhoneBlackmagicModelVariantsToBaseIPhoneModel() {
        let candidate = MediaCandidate(
            absolutePath: "/source/PRIVATE/A001_10102145_C001.mov",
            relativePath: "PRIVATE/A001_10102145_C001.mov",
            mediaType: .video,
            sizeBytes: 42,
            mtime: Date(timeIntervalSince1970: 1_700_000_000),
            photoMetadata: nil,
            videoMetadata: VideoMetadata(
                captureDateTime: Date(timeIntervalSince1970: 1_700_000_100),
                captureDateSource: .creationTime,
                usedFallback: false,
                cameraMake: nil,
                cameraModel: "Apple iPhone 15 Pro 48mm",
                cameraSerial: nil
            )
        )

        let inferred = CameraLabeler().infer(for: candidate)
        XCTAssertEqual(inferred.cameraLabel, "iphone-15-pro")
    }

    func testInferNormalizesDJIModelPrefixesAndKeepsPhotoVideoLabelConsistent() {
        let photoCandidate = MediaCandidate(
            absolutePath: "/source/DCIM/100/DJI_0001.DNG",
            relativePath: "DCIM/100/DJI_0001.DNG",
            mediaType: .photo,
            sizeBytes: 42,
            mtime: Date(timeIntervalSince1970: 1_700_000_000),
            photoMetadata: PhotoMetadata(
                captureDateTime: Date(timeIntervalSince1970: 1_700_000_100),
                captureDateSource: .dateTimeOriginal,
                cameraMake: "DJI",
                cameraModel: "Mini4 Pro",
                cameraSerial: "TESTSERIAL0001"
            )
        )
        let videoCandidate = MediaCandidate(
            absolutePath: "/source/DCIM/100/DJI_0001.MP4",
            relativePath: "DCIM/100/DJI_0001.MP4",
            mediaType: .video,
            sizeBytes: 42,
            mtime: Date(timeIntervalSince1970: 1_700_000_000),
            photoMetadata: nil,
            videoMetadata: VideoMetadata(
                captureDateTime: Date(timeIntervalSince1970: 1_700_000_100),
                captureDateSource: .creationTime,
                usedFallback: false,
                cameraMake: nil,
                cameraModel: "DJI Mini4 Pro",
                cameraSerial: nil
            )
        )

        let labeler = CameraLabeler()
        XCTAssertEqual(labeler.infer(for: photoCandidate).cameraLabel, "mini4-pro")
        XCTAssertEqual(labeler.infer(for: videoCandidate).cameraLabel, "mini4-pro")
    }

    func testInferNormalizesDJIMini3ModelPrefixesAndKeepsPhotoVideoLabelConsistent() {
        let photoCandidate = MediaCandidate(
            absolutePath: "/source/DCIM/100/DJI_0002.DNG",
            relativePath: "DCIM/100/DJI_0002.DNG",
            mediaType: .photo,
            sizeBytes: 42,
            mtime: Date(timeIntervalSince1970: 1_700_000_000),
            photoMetadata: PhotoMetadata(
                captureDateTime: Date(timeIntervalSince1970: 1_700_000_100),
                captureDateSource: .dateTimeOriginal,
                cameraMake: "DJI",
                cameraModel: "Mini3 Pro",
                cameraSerial: nil
            )
        )
        let videoCandidate = MediaCandidate(
            absolutePath: "/source/DCIM/100/DJI_0002.MP4",
            relativePath: "DCIM/100/DJI_0002.MP4",
            mediaType: .video,
            sizeBytes: 42,
            mtime: Date(timeIntervalSince1970: 1_700_000_000),
            photoMetadata: nil,
            videoMetadata: VideoMetadata(
                captureDateTime: Date(timeIntervalSince1970: 1_700_000_100),
                captureDateSource: .creationTime,
                usedFallback: false,
                cameraMake: nil,
                cameraModel: "DJI Mini3 Pro",
                cameraSerial: nil
            )
        )

        let labeler = CameraLabeler()
        XCTAssertEqual(labeler.infer(for: photoCandidate).cameraLabel, "mini3-pro")
        XCTAssertEqual(labeler.infer(for: videoCandidate).cameraLabel, "mini3-pro")
    }

    func testInferNormalizesDJIOsmoAction6ModelPrefix() {
        let videoCandidate = MediaCandidate(
            absolutePath: "/source/DCIM/100MEDIA/DJI_20260613062714_0010_D.MP4",
            relativePath: "DCIM/100MEDIA/DJI_20260613062714_0010_D.MP4",
            mediaType: .video,
            sizeBytes: 42,
            mtime: Date(timeIntervalSince1970: 1_700_000_000),
            photoMetadata: nil,
            videoMetadata: VideoMetadata(
                captureDateTime: Date(timeIntervalSince1970: 1_700_000_100),
                captureDateSource: .creationTime,
                usedFallback: false,
                cameraMake: nil,
                cameraModel: "DJI OsmoAction6",
                cameraSerial: nil
            )
        )

        let labeler = CameraLabeler()
        XCTAssertEqual(labeler.infer(for: videoCandidate).cameraLabel, "osmoaction6")
    }

    func testInferReturnsFixedAudioLabelRegardlessOfMetadata() {
        let candidate = MediaCandidate(
            absolutePath: "/source/DCIM/iphone recording.m4a",
            relativePath: "DCIM/iphone recording.m4a",
            mediaType: .audio,
            sizeBytes: 35_455,
            mtime: Date(timeIntervalSince1970: 1_700_000_000),
            audioMetadata: AudioMetadata(
                captureDateTime: Date(timeIntervalSince1970: 1_700_000_100),
                captureDateSource: .creationTime,
                usedFallback: false
            )
        )

        let inferred = CameraLabeler().infer(for: candidate)
        XCTAssertEqual(inferred.cameraLabel, "audio")
        XCTAssertNil(inferred.make)
        XCTAssertNil(inferred.model)
        XCTAssertNil(inferred.serial)
    }

    func testAssessCardCarriesFirstRawModelCodePerLabelAndNoneForUnknownOrAudio() {
        func photo(_ name: String, model: String?) -> MediaCandidate {
            MediaCandidate(
                absolutePath: "/source/DCIM/\(name)",
                relativePath: "DCIM/\(name)",
                mediaType: .photo,
                sizeBytes: 10,
                mtime: Date(timeIntervalSince1970: 1_700_000_000),
                photoMetadata: PhotoMetadata(
                    captureDateTime: Date(timeIntervalSince1970: 1_700_000_010),
                    captureDateSource: .dateTimeOriginal,
                    cameraMake: model == nil ? nil : "samsung",
                    cameraModel: model,
                    cameraSerial: nil
                )
            )
        }
        let audio = MediaCandidate(
            absolutePath: "/source/DCIM/rec.m4a",
            relativePath: "DCIM/rec.m4a",
            mediaType: .audio,
            sizeBytes: 10,
            mtime: Date(timeIntervalSince1970: 1_700_000_000),
            audioMetadata: AudioMetadata(
                captureDateTime: Date(timeIntervalSince1970: 1_700_000_100),
                captureDateSource: .creationTime,
                usedFallback: false
            )
        )

        let assessment = CameraLabeler().assessCard(candidates: [
            photo("A.JPG", model: " SM-A546B "),
            photo("B.JPG", model: "SM-A546B"),
            photo("C.JPG", model: nil),
            audio,
        ])

        let rawByLabel = Dictionary(uniqueKeysWithValues: assessment.distribution.map { ($0.cameraLabel, $0.rawModelCode) })
        XCTAssertEqual(rawByLabel["sm-a546b"] ?? nil, "SM-A546B")
        XCTAssertNil(rawByLabel["unknown-camera"] ?? nil)
        XCTAssertNil(rawByLabel["audio"] ?? nil)
        XCTAssertEqual(assessment.totalCandidates, 4)
    }

    func testDistributionEntryRawModelCodeDefaultsToNilForProgressPath() {
        let entry = CameraDistributionEntry(cameraLabel: "eos-r5", fileCount: 3)
        XCTAssertNil(entry.rawModelCode)
        XCTAssertEqual(entry.rawModelCodes, [])
    }

    func testAssessCardListsEveryDistinctRawModelCodeBehindOneLabel() {
        func photo(_ name: String, model: String) -> MediaCandidate {
            MediaCandidate(
                absolutePath: "/source/DCIM/\(name)",
                relativePath: "DCIM/\(name)",
                mediaType: .photo,
                sizeBytes: 10,
                mtime: Date(timeIntervalSince1970: 1_700_000_000),
                photoMetadata: PhotoMetadata(
                    captureDateTime: Date(timeIntervalSince1970: 1_700_000_010),
                    captureDateSource: .dateTimeOriginal,
                    cameraMake: "Apple",
                    cameraModel: model,
                    cameraSerial: nil
                )
            )
        }

        let assessment = CameraLabeler().assessCard(candidates: [
            photo("A.HEIC", model: "iPhone 15 Pro"),
            photo("B.HEIC", model: "Apple iPhone 15 Pro 13mm"),
            photo("C.HEIC", model: "iPhone 15 Pro"),
        ])

        XCTAssertEqual(assessment.distribution.count, 1)
        XCTAssertEqual(assessment.distribution[0].fileCount, 3)
        XCTAssertEqual(assessment.distribution[0].rawModelCodes, ["iPhone 15 Pro", "Apple iPhone 15 Pro 13mm"])
        XCTAssertEqual(assessment.distribution[0].rawModelCode, "iPhone 15 Pro")
    }
}
