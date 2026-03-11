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

        XCTAssertEqual(inference.cameraLabel, "apple")
        XCTAssertEqual(planned.cameraLabel, "apple")
        XCTAssertTrue(planned.finalPath.hasSuffix("/2026/202602/apple/Videos/IMG_8469.mov"))
        XCTAssertEqual(preparation.cameraAssessment.cameraLabel, "apple")
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
}
