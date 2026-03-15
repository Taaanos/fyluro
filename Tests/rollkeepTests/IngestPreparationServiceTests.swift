import Foundation
import XCTest
@testable import RollKeepCore

final class IngestPreparationServiceTests: XCTestCase {
    private var tempRoot: URL!

    override func setUpWithError() throws {
        let unique = "rollkeep-preparation-tests-\(UUID().uuidString.lowercased())"
        tempRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(unique, isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
    }

    func testPreparePlansKnownVideoWithMatchingCameraLabel() throws {
        let sourceRoot = fixtureURL("TestingDirs/TESTCOPY/Videos/2026/022026/iphone-15-pro")
        let preparation = try IngestPreparationService().prepare(
            sourceRoot: sourceRoot,
            destRoot: tempRoot,
            sessionID: "session-known-video"
        )

        let candidate = try XCTUnwrap(preparation.scanSummary.candidates.first {
            $0.relativePath == "IMG_8469.mov"
        })
        let inference = preparation.cameraInference(for: candidate)
        let planned = try XCTUnwrap(preparation.plan?.files.first {
            $0.candidate.absolutePath == candidate.absolutePath
        })

        XCTAssertEqual(inference.cameraLabel, "iphone-15-pro")
        XCTAssertEqual(planned.cameraLabel, "iphone-15-pro")
        XCTAssertTrue(planned.finalPath.hasSuffix("/2026/202602/iphone-15-pro/Videos/IMG_8469.mov"))
        XCTAssertEqual(preparation.cameraAssessment.cameraLabel, "iphone-15-pro")
    }

    func testPrepareNormalizesCameraLabelsAcrossIPhoneCameraApps() throws {
        let sourceRoot = fixtureURL("normalize-camera-models")
        let preparation = try IngestPreparationService().prepare(
            sourceRoot: sourceRoot,
            destRoot: tempRoot,
            sessionID: "session-iphone-normalization"
        )

        var labelsByPath: [String: String] = [:]
        for candidate in preparation.scanSummary.candidates {
            labelsByPath[candidate.relativePath] = preparation.cameraInference(for: candidate).cameraLabel
        }

        XCTAssertEqual(labelsByPath["IMG_4690.MOV"], "iphone-13")
        XCTAssertEqual(labelsByPath["A001_10102145_C001.mov"], "iphone-15-pro")
        XCTAssertEqual(preparation.cameraAssessment.distribution.map(\.cameraLabel), ["iphone-13", "iphone-15-pro"])
    }

    func testPrepareFallsBackToUnknownCameraWhenVideoMetadataIdentityCannotBeResolved() throws {
        let sourceRoot = fixtureURL("TestingDirs/TESTCOPY1/2026/012026/unknown-camera/Videos")
        let preparation = try IngestPreparationService().prepare(
            sourceRoot: sourceRoot,
            destRoot: tempRoot,
            sessionID: "session-unknown-video"
        )

        let candidate = try XCTUnwrap(preparation.scanSummary.candidates.first {
            $0.relativePath == "att.KmP_GwtF0Xrpjay5Ibkk-JM1F-9unFQ1gCupw_G3CME.MP4"
        })
        let inference = preparation.cameraInference(for: candidate)
        let planned = try XCTUnwrap(preparation.plan?.files.first {
            $0.candidate.absolutePath == candidate.absolutePath
        })

        XCTAssertEqual(inference.cameraLabel, "unknown-camera")
        XCTAssertEqual(planned.cameraLabel, "unknown-camera")
        XCTAssertTrue(planned.finalPath.contains("/unknown-camera/Videos/att.KmP_GwtF0Xrpjay5Ibkk-JM1F-9unFQ1gCupw_G3CME.MP4"))
        XCTAssertEqual(preparation.cameraAssessment.cameraLabel, "unknown-camera")
    }

    func testPrepareAvoidsGenericVideoTokenLabelsForUnknownTagFixture() throws {
        let sourceRoot = fixtureURL("unknown-tag")
        let preparation = try IngestPreparationService().prepare(
            sourceRoot: sourceRoot,
            destRoot: tempRoot,
            sessionID: "session-unknown-tag-videos"
        )

        var labelsByPath: [String: String] = [:]
        for candidate in preparation.scanSummary.candidates {
            labelsByPath[candidate.relativePath] = preparation.cameraInference(for: candidate).cameraLabel
        }

        XCTAssertEqual(labelsByPath["20250823_C2851.MOV"], "unknown-camera")
        XCTAssertEqual(labelsByPath["GOPR1046.MP4"], "unknown-camera")
        XCTAssertEqual(preparation.cameraAssessment.cameraLabel, "unknown-camera")
        XCTAssertEqual(preparation.cameraAssessment.unknownCameraFileCount, 2)
    }

    func testPrepareUsesVideoSidecarMetadataAndPlansSidecarTransfer() throws {
        let movieURL = try createFile(path: "PRIVATE/MVI_8241.MOV", bytes: 256)
        _ = try createFile(path: "PRIVATE/MVI_8241.THM", bytes: 64)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_241_797_896)],
            ofItemAtPath: movieURL.path
        )

        let preparationService = IngestPreparationService(
            sourceScanner: SourceScanner(
                photoMetadataExtractor: IngestPreparationNoopPhotoExtractor(),
                videoMetadataExtractor: IngestPreparationStubVideoExtractor()
            )
        )

        let preparation = try preparationService.prepare(
            sourceRoot: tempRoot,
            destRoot: tempRoot,
            sessionID: "session-video-sidecars"
        )

        let movieCandidate = try XCTUnwrap(preparation.scanSummary.candidates.first {
            $0.relativePath == "PRIVATE/MVI_8241.MOV"
        })
        let metadata = try XCTUnwrap(movieCandidate.videoMetadata)
        XCTAssertEqual(metadata.captureDateSource, .sidecarMetadata)

        let inference = preparation.cameraInference(for: movieCandidate)
        XCTAssertEqual(inference.cameraLabel, "canon-eos-5d-mark-ii")

        let plannedFiles = preparation.plan?.files.map(\.candidate.relativePath) ?? []
        XCTAssertTrue(plannedFiles.contains("PRIVATE/MVI_8241.MOV"))
        XCTAssertTrue(plannedFiles.contains("PRIVATE/MVI_8241.THM"))
    }

    func testPrepareUsesDJIMetadataFixtureForMixedCameraDistribution() throws {
        let preparation = try IngestPreparationService().prepare(
            sourceRoot: fixtureURL("dji-metadata"),
            destRoot: tempRoot,
            sessionID: "session-dji-metadata"
        )

        XCTAssertEqual(preparation.scanSummary.candidates.count, 4)
        XCTAssertEqual(preparation.scanSummary.photoCount, 4)
        XCTAssertEqual(preparation.scanSummary.videoCount, 0)
        XCTAssertEqual(preparation.cameraAssessment.cameraLabel, CameraLabeler.mixedLabel)
        XCTAssertTrue(preparation.cameraAssessment.mixedCameraDetected)
        XCTAssertEqual(preparation.cameraAssessment.unknownCameraFileCount, 0)

        let distributionByLabel = Dictionary(
            uniqueKeysWithValues: preparation.cameraAssessment.distribution.map { ($0.cameraLabel, $0.fileCount) }
        )
        XCTAssertEqual(distributionByLabel["mini4-pro-sn-f0m2x65v"], 3)
        XCTAssertEqual(distributionByLabel["fc220-sn-14031100"], 1)

        let dji0761 = try XCTUnwrap(preparation.scanSummary.candidates.first { $0.relativePath == "DJI_0761.JPG" })
        XCTAssertEqual(preparation.cameraInference(for: dji0761).cameraLabel, "fc220-sn-14031100")
    }

    func testPrepareUsesMtimeFallbackForNoVideoMetadataFixture() throws {
        let preparation = try IngestPreparationService().prepare(
            sourceRoot: fixtureURL("no-video-metadata"),
            destRoot: tempRoot,
            sessionID: "session-no-video-metadata"
        )

        let candidate = try XCTUnwrap(preparation.scanSummary.candidates.first {
            $0.relativePath == "MVI_8216.MOV"
        })
        let metadata = try XCTUnwrap(candidate.videoMetadata)
        XCTAssertEqual(metadata.captureDateSource, .mtimeFallback)
        XCTAssertTrue(metadata.usedFallback)
        XCTAssertEqual(preparation.cameraInference(for: candidate).cameraLabel, "unknown-camera")

        let planned = try XCTUnwrap(preparation.plan?.files.first {
            $0.candidate.absolutePath == candidate.absolutePath
        })
        XCTAssertTrue(planned.finalPath.hasSuffix("/unknown-camera/Videos/MVI_8216.MOV"))
        XCTAssertFalse(planned.finalPath.contains("/_unsorted/"))
    }

    func testPrepareUsesRealVideoSidecarFixturesForSonyXMLAndTHM() throws {
        let preparation = try IngestPreparationService().prepare(
            sourceRoot: fixtureURL("video-sidecars"),
            destRoot: tempRoot,
            sessionID: "session-real-video-sidecars"
        )

        let movCandidate = try XCTUnwrap(preparation.scanSummary.candidates.first {
            $0.relativePath == "MVI_8241.MOV"
        })
        let movMetadata = try XCTUnwrap(movCandidate.videoMetadata)
        XCTAssertEqual(movMetadata.captureDateSource, .sidecarMetadata)
        XCTAssertEqual(preparation.cameraInference(for: movCandidate).cameraLabel, "canon-eos-5d-mark-ii")
        XCTAssertEqual(movCandidate.sidecars.map(\.relativePath), ["MVI_8241.THM"])

        let mp4Candidate = try XCTUnwrap(preparation.scanSummary.candidates.first {
            $0.relativePath == "20251219_C3501.MP4"
        })
        XCTAssertEqual(preparation.cameraInference(for: mp4Candidate).cameraLabel, "ilce-7cm2")
        XCTAssertEqual(mp4Candidate.sidecars.map(\.relativePath), ["20251219_C3501M01.XML"])

        let plannedByPath = Dictionary(uniqueKeysWithValues: (preparation.plan?.files ?? []).map { ($0.candidate.relativePath, $0) })
        XCTAssertEqual(plannedByPath.count, 4)
        XCTAssertEqual(plannedByPath["MVI_8241.THM"]?.cameraLabel, "canon-eos-5d-mark-ii")
        XCTAssertEqual(plannedByPath["20251219_C3501M01.XML"]?.cameraLabel, "ilce-7cm2")
    }

    func testPrepareDetectsSonyVideoFixtureCameraLabel() throws {
        let preparation = try IngestPreparationService().prepare(
            sourceRoot: fixtureURL("sony-video"),
            destRoot: tempRoot,
            sessionID: "session-sony-video"
        )

        let candidate = try XCTUnwrap(preparation.scanSummary.candidates.first {
            $0.relativePath == "20251014_C3017.MP4"
        })
        XCTAssertEqual(preparation.cameraInference(for: candidate).cameraLabel, "ilce-7cm2")
        XCTAssertEqual(preparation.cameraAssessment.cameraLabel, "ilce-7cm2")
        XCTAssertFalse(preparation.cameraAssessment.mixedCameraDetected)
    }

    func testPrepareKeepsBugUnsortedFixtureInDatedBucketsViaFallback() throws {
        let preparation = try IngestPreparationService().prepare(
            sourceRoot: fixtureURL("bug-unsorted"),
            destRoot: tempRoot,
            sessionID: "session-bug-unsorted"
        )

        XCTAssertEqual(preparation.scanSummary.candidates.count, 21)
        XCTAssertEqual(preparation.scanSummary.photoCount, 20)
        XCTAssertEqual(preparation.scanSummary.videoCount, 1)
        XCTAssertEqual(preparation.cameraAssessment.cameraLabel, "unknown-camera")
        XCTAssertEqual(preparation.cameraAssessment.unknownCameraFileCount, 21)

        let plannedFiles = preparation.plan?.files ?? []
        XCTAssertEqual(plannedFiles.count, 21)
        XCTAssertFalse(plannedFiles.contains { $0.finalPath.contains("/_unsorted/") })
    }

    func testPrepareInventoriesAllCameraLabelsForSDCard2Fixture() throws {
        let preparation = try IngestPreparationService().prepare(
            sourceRoot: fixtureURL("TestingDirs/SD_CARD2"),
            destRoot: tempRoot,
            sessionID: "session-sdcard2-inventory"
        )

        XCTAssertEqual(preparation.scanSummary.candidates.count, 16)
        XCTAssertEqual(preparation.scanSummary.photoCount, 13)
        XCTAssertEqual(preparation.scanSummary.videoCount, 3)

        let assessment = preparation.cameraAssessment
        XCTAssertEqual(assessment.cameraLabel, CameraLabeler.mixedLabel)
        XCTAssertTrue(assessment.mixedCameraDetected)
        XCTAssertEqual(assessment.totalCandidates, 16)
        XCTAssertEqual(assessment.knownCameraFileCount, 13)
        XCTAssertEqual(assessment.unknownCameraFileCount, 3)

        let distributionByLabel = Dictionary(
            uniqueKeysWithValues: assessment.distribution.map { ($0.cameraLabel, $0.fileCount) }
        )
        XCTAssertEqual(distributionByLabel["iphone-15-pro"], 8)
        XCTAssertEqual(distributionByLabel["unknown-camera"], 3)
        XCTAssertEqual(distributionByLabel["dsc-rx100"], 1)
        XCTAssertEqual(distributionByLabel["fc220-sn-14031100"], 1)
        XCTAssertEqual(distributionByLabel["ilce-7cm2"], 1)
        XCTAssertEqual(distributionByLabel["iphone-13"], 1)
        XCTAssertEqual(distributionByLabel["mini4-pro-sn-f0m2x65v"], 1)

        let planned = preparation.plan?.files ?? []
        XCTAssertEqual(planned.count, 16)
        XCTAssertFalse(planned.contains { $0.finalPath.contains("/_unsorted/") })
    }

    func testPrepareInventoriesSingleCameraForSDCard1Fixture() throws {
        let preparation = try IngestPreparationService().prepare(
            sourceRoot: fixtureURL("TestingDirs/SD_CARD1"),
            destRoot: tempRoot,
            sessionID: "session-sdcard1-inventory"
        )

        XCTAssertEqual(preparation.scanSummary.candidates.count, 9)
        XCTAssertEqual(preparation.scanSummary.photoCount, 8)
        XCTAssertEqual(preparation.scanSummary.videoCount, 1)

        let assessment = preparation.cameraAssessment
        XCTAssertEqual(assessment.cameraLabel, "iphone-15-pro")
        XCTAssertFalse(assessment.mixedCameraDetected)
        XCTAssertEqual(assessment.totalCandidates, 9)
        XCTAssertEqual(assessment.knownCameraFileCount, 9)
        XCTAssertEqual(assessment.unknownCameraFileCount, 0)
        XCTAssertEqual(assessment.distribution.map(\.cameraLabel), ["iphone-15-pro"])
        XCTAssertEqual(assessment.distribution.map(\.fileCount), [9])

        let planned = preparation.plan?.files ?? []
        XCTAssertEqual(planned.count, 9)
        XCTAssertFalse(planned.contains { $0.finalPath.contains("/_unsorted/") })
    }

    func testPrepareIncludesSonyXMLCompanionFilesForDuplicatesSource1Fixture() throws {
        let preparation = try IngestPreparationService().prepare(
            sourceRoot: fixtureURL("TestingDirs/DUPLICATES/SOURCE1"),
            destRoot: tempRoot,
            sessionID: "session-duplicates-source1"
        )

        XCTAssertEqual(preparation.scanSummary.candidates.count, 12)
        XCTAssertEqual(preparation.cameraAssessment.cameraLabel, "ilce-7cm2")
        XCTAssertFalse(preparation.cameraAssessment.mixedCameraDetected)
        XCTAssertEqual(preparation.cameraAssessment.unknownCameraFileCount, 0)

        let plannedPaths = Set(preparation.plan?.files.map(\.candidate.relativePath) ?? [])
        XCTAssertEqual(plannedPaths.count, 16)
        XCTAssertTrue(plannedPaths.contains("CLIP1/20251219_C3499M01.XML"))
        XCTAssertTrue(plannedPaths.contains("CLIP1/20251219_C3500M01.XML"))
        XCTAssertTrue(plannedPaths.contains("CLIP1/20251219_C3501M01.XML"))
        XCTAssertTrue(plannedPaths.contains("CLIP1/20251219_C3502M01.XML"))
    }

    func testPrepareResolvesSameBasenameAcrossDifferentDirsWithDeterministicSuffix() throws {
        let preparation = try IngestPreparationService().prepare(
            sourceRoot: fixtureURL("bug-duplicate-different-dirs"),
            destRoot: tempRoot,
            sessionID: "session-duplicate-different-dirs"
        )

        XCTAssertEqual(preparation.scanSummary.candidates.count, 2)
        XCTAssertEqual(preparation.scanSummary.photoCount, 2)
        XCTAssertEqual(preparation.scanSummary.videoCount, 0)
        XCTAssertEqual(preparation.cameraAssessment.cameraLabel, "iphone-7-plus")
        XCTAssertEqual(preparation.cameraAssessment.unknownCameraFileCount, 0)

        let planned = preparation.plan?.files ?? []
        XCTAssertEqual(planned.count, 2)
        XCTAssertEqual(planned.filter { $0.disposition == .duplicateNotCopied }.count, 0)

        let finalPaths = Set(planned.map(\.finalPath))
        XCTAssertEqual(finalPaths.count, 2)
        XCTAssertTrue(finalPaths.contains { $0.hasSuffix("/2018/201806/iphone-7-plus/Photos/IMG_6481.jpg") })
        XCTAssertTrue(finalPaths.contains { $0.hasSuffix("/2018/201806/iphone-7-plus/Photos/IMG_6481-1.JPG") })
        XCTAssertEqual(planned.filter(\.collisionResolved).count, 1)
    }

    private func fixtureURL(_ relativePath: String) -> URL {
        repoRootURL
            .appendingPathComponent("Tests", isDirectory: true)
            .appendingPathComponent(relativePath, isDirectory: true)
    }

    private var repoRootURL: URL {
        URL(fileURLWithPath: #filePath, isDirectory: false)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    @discardableResult
    private func createFile(path: String, bytes: Int) throws -> URL {
        let fileURL = tempRoot.appendingPathComponent(path, isDirectory: false)
        let dirURL = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)

        let data = Data(repeating: 0x41, count: bytes)
        FileManager.default.createFile(atPath: fileURL.path, contents: data)
        return fileURL
    }
}

private struct IngestPreparationNoopPhotoExtractor: PhotoMetadataExtracting {
    func extract(from fileURL: URL) -> PhotoMetadata {
        PhotoMetadata(
            captureDateTime: nil,
            captureDateSource: .missing,
            cameraMake: nil,
            cameraModel: nil,
            cameraSerial: nil
        )
    }
}

private struct IngestPreparationStubVideoExtractor: VideoMetadataExtracting {
    func extract(from fileURL: URL, fallbackMtime: Date) -> VideoMetadata {
        if fileURL.lastPathComponent == "MVI_8241.MOV" {
            return VideoMetadata(
                captureDateTime: Date(timeIntervalSince1970: 1_241_797_889),
                captureDateSource: .sidecarMetadata,
                usedFallback: false,
                cameraMake: "Canon",
                cameraModel: "Canon EOS 5D Mark II",
                cameraSerial: nil
            )
        }

        return VideoMetadata(
            captureDateTime: fallbackMtime,
            captureDateSource: .mtimeFallback,
            usedFallback: true,
            cameraMake: nil,
            cameraModel: nil,
            cameraSerial: nil
        )
    }
}
