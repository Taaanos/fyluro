import Foundation
import XCTest
@testable import RollKeepCore
@testable import rollkeep

final class ScanFileListBuilderTests: XCTestCase {
    private var tempRoot: URL!

    override func setUpWithError() throws {
        let unique = "rollkeep-scan-file-list-tests-\(UUID().uuidString.lowercased())"
        tempRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(unique, isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
    }

    func testBuildScanFileListEntriesIncludesCameraEvidenceAndLegacyCameraFields() throws {
        let preparation = try IngestPreparationService().prepare(
            sourceRoot: fixtureURL("mini4-pro-photo"),
            destRoot: tempRoot,
            sessionID: "scan-file-list-mini4"
        )
        let plan = try XCTUnwrap(preparation.plan)
        let formatter = ISO8601DateFormatter()

        let entries = buildScanFileListEntries(
            summary: preparation.scanSummary,
            plan: plan,
            cameraInferenceByPath: preparation.cameraInferenceByPath,
            preparation: preparation,
            isoFormatter: formatter
        )

        XCTAssertEqual(entries.count, 1)
        let first = try XCTUnwrap(entries.first)
        XCTAssertEqual(first["camera_label"] as? String, "mini4-pro")
        XCTAssertEqual(first["camera_make"] as? String, "DJI")
        XCTAssertEqual(first["camera_model"] as? String, "Mini4 Pro")
        XCTAssertEqual(first["camera_serial"] as? String, "TESTSERIAL0001")

        let evidence = try XCTUnwrap(first["camera_evidence"] as? [String: Any])
        let model = try XCTUnwrap(evidence["model"] as? [String: String])
        XCTAssertEqual(model["value"], "Mini4 Pro")
        XCTAssertEqual(model["source"], "xmp_product_name")
        XCTAssertEqual(model["selection_rule"], "prefer_supplemental_for_opaque_primary_model_code")

        let make = try XCTUnwrap(evidence["make"] as? [String: String])
        XCTAssertEqual(make["value"], "DJI")
        XCTAssertEqual(make["source"], "tiff_make")
    }

    func testBuildScanFileListEntriesKeepsScanCandidateOrder() throws {
        let preparation = try IngestPreparationService().prepare(
            sourceRoot: fixtureURL("dji-metadata"),
            destRoot: tempRoot,
            sessionID: "scan-file-list-order"
        )
        let plan = try XCTUnwrap(preparation.plan)
        let formatter = ISO8601DateFormatter()

        let entries = buildScanFileListEntries(
            summary: preparation.scanSummary,
            plan: plan,
            cameraInferenceByPath: preparation.cameraInferenceByPath,
            preparation: preparation,
            isoFormatter: formatter
        )

        XCTAssertEqual(entries.map { $0["path"] as? String }, preparation.scanSummary.candidates.map(\.relativePath))
    }

    private func fixtureURL(_ name: String) -> URL {
        let root = URL(fileURLWithPath: #filePath, isDirectory: false)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return root.appendingPathComponent("Tests/\(name)", isDirectory: true)
    }
}
