import Foundation
import XCTest
@testable import RollKeepCore

/// ROL-6 Section 6, "Experimental setting": a run that turns the catalog off uses the raw model
/// code, even when a catalog file exists.
final class CameraCatalogOffTests: XCTestCase {
    private var catalogURL: URL!
    private var previousOverride: String?

    override func setUpWithError() throws {
        previousOverride = ProcessInfo.processInfo.environment[CameraUserCatalogFileLocation.environmentOverrideKey]
        catalogURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rollkeep-catalog-off-\(UUID().uuidString).json")
        try #"{"AC006": "Osmo Action 6"}"#.write(to: catalogURL, atomically: true, encoding: .utf8)
        setenv(CameraUserCatalogFileLocation.environmentOverrideKey, catalogURL.path, 1)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: catalogURL)
        if let previousOverride {
            setenv(CameraUserCatalogFileLocation.environmentOverrideKey, previousOverride, 1)
        } else {
            unsetenv(CameraUserCatalogFileLocation.environmentOverrideKey)
        }
    }

    private func candidate(model: String) -> MediaCandidate {
        MediaCandidate(
            absolutePath: "/source/DCIM/100/IMG_0001.JPG",
            relativePath: "DCIM/100/IMG_0001.JPG",
            mediaType: .photo,
            sizeBytes: 42,
            mtime: Date(timeIntervalSince1970: 1_700_000_000),
            photoMetadata: PhotoMetadata(
                captureDateTime: Date(timeIntervalSince1970: 1_700_000_100),
                captureDateSource: .dateTimeOriginal,
                cameraMake: "DJI",
                cameraModel: model,
                cameraSerial: nil
            )
        )
    }

    func testRunWithCatalogOnUsesTheCatalogName() {
        let labeler = CameraLabeler.forRun(usingUserCatalog: true)

        XCTAssertEqual(labeler.infer(for: candidate(model: "AC006")).cameraLabel, "osmo-action-6")
    }

    func testRunWithCatalogOffUsesTheRawModelCode() {
        let labeler = CameraLabeler.forRun(usingUserCatalog: false)

        XCTAssertEqual(labeler.infer(for: candidate(model: "AC006")).cameraLabel, "ac006")
    }

    func testCatalogOffStillAppliesTheRulesAfterTheCatalogLookup() {
        let labeler = CameraLabeler.forRun(usingUserCatalog: false)

        XCTAssertEqual(labeler.infer(for: candidate(model: "Apple iPhone 15 Pro 48mm")).cameraLabel, "iphone-15-pro")
    }

    func testCatalogOffLeavesTheCatalogFileUntouched() throws {
        let before = try Data(contentsOf: catalogURL)

        _ = CameraLabeler.forRun(usingUserCatalog: false).infer(for: candidate(model: "AC006"))

        XCTAssertEqual(try Data(contentsOf: catalogURL), before)
    }
}
