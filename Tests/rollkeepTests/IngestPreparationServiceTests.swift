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
        let sourceRoot = URL(
            fileURLWithPath: "Tests/TestingDirs/TESTCOPY/Videos/2026/022026/iphone-15-pro",
            isDirectory: true
        )
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
        let sourceRoot = URL(
            fileURLWithPath: "Tests/normalize-camera-models",
            isDirectory: true
        )
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
        let sourceRoot = URL(
            fileURLWithPath: "Tests/TestingDirs/TESTCOPY1/2026/012026/unknown-camera/Videos",
            isDirectory: true
        )
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
        let sourceRoot = URL(
            fileURLWithPath: "Tests/unknown-tag",
            isDirectory: true
        )
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
