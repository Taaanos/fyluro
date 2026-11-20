import Foundation
import XCTest
@testable import FyluroCore

/// End-to-end camera-*labeling* regression sweep across every photo and
/// video fixture under `Tests/TestingDirs` (or `FYLURO_TESTING_FIXTURES`).
///
/// `CameraMetadataFixtureRegressionTests` already covers raw make/model/
/// serial extraction for videos, but stops before `CameraLabeler` --
/// it never exercises `CameraIdentityLabelNormalizer`'s model-code lookup.
/// This test drives the full photo+video pipeline through to the folder
/// label, against an injected catalog seeded with the DJI/Samsung mappings the
/// user would have added, so a regression in raw-code extraction or in the
/// code-to-name lookup shows up here even though the box-walk-level test
/// would stay green.
final class CameraLabelFixtureRegressionTests: XCTestCase {
    private struct LabeledFile {
        let relativePath: String
        let cameraLabel: String
    }

    private static let seededLabeler = CameraLabeler(
        identityNormalizer: CameraIdentityLabelNormalizer(
            ruleRegistry: CameraModelLabelRuleRegistry(
                rules: [
                    MapKnownModelCodeToProductNameRule(modelCodeMap: [
                        "AC003": "OsmoAction4",
                        "AC006": "OsmoAction6",
                        "FC8482": "Mini4 Pro",
                        "PP-101": "OsmoPocket3",
                        "SM-A546B": "Galaxy A54 5G",
                    ]),
                ] + CameraModelLabelRuleRegistry.postCatalogRules
            )
        )
    )

    private static var fixturesRoot: URL {
        if let override = ProcessInfo.processInfo.environment["FYLURO_TESTING_FIXTURES"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return URL(fileURLWithPath: #filePath, isDirectory: false)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("TestingDirs", isDirectory: true)
    }

    func testLabelsAcrossRealFixturesReportAndKnownMappingsHold() throws {
        let fixturesRoot = Self.fixturesRoot
        guard FileManager.default.fileExists(atPath: fixturesRoot.path) else {
            throw XCTSkip("Fixtures directory not present: \(fixturesRoot.path)")
        }

        let mediaFiles = try Self.discoverMediaFiles(under: fixturesRoot)
        guard !mediaFiles.isEmpty else {
            throw XCTSkip("No photo/video fixtures found under \(fixturesRoot.path)")
        }

        let labeled = mediaFiles
            .map { Self.label(fileURL: $0, fixturesRoot: fixturesRoot) }
            .sorted { $0.relativePath < $1.relativePath }

        // Printed for manual before/after diffing across refactors.
        print(labeled.map { "\($0.relativePath) -> \($0.cameraLabel)" }.joined(separator: "\n"))

        // The raw-code-never-leaks invariant is more robust than an exact
        // before/after diff to hand-maintain here: it holds regardless of
        // which fixtures happen to be present locally.
        Self.assertKnownMapping(
            labeled, pathFragment: "DJI_20260523", rawCode: "fc8482", expectedLabelSubstring: "mini4-pro"
        )
        Self.assertKnownMapping(
            labeled, pathFragment: "DJI_20240126", rawCode: "pp-101", expectedLabelSubstring: "osmopocket3"
        )
        Self.assertKnownMapping(
            labeled, pathFragment: "20240809_16", rawCode: "sm-a546b", expectedLabelSubstring: "galaxy-a54-5g"
        )
        Self.assertKnownMapping(
            labeled, pathFragment: "DJI_202402", rawCode: "ac003", expectedLabelSubstring: "osmoaction4"
        )
        Self.assertKnownMapping(
            labeled, pathFragment: "DJI_20260613", rawCode: "ac006", expectedLabelSubstring: "osmoaction6"
        )
    }

    private static func discoverMediaFiles(under fixturesRoot: URL) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: fixturesRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var results: [URL] = []
        while let url = enumerator.nextObject() as? URL {
            guard !url.path.contains("/E2E_EXISTING_HDD_") else { continue }
            let ext = url.pathExtension.lowercased()
            guard SourceScannerTraversal.photoExtensions.contains(ext)
                || SourceScannerTraversal.videoExtensions.contains(ext)
            else {
                continue
            }
            results.append(url)
        }
        return results
    }

    private static func label(fileURL: URL, fixturesRoot: URL) -> LabeledFile {
        let relativePath = fileURL.path.replacingOccurrences(of: fixturesRoot.path + "/", with: "")
        let ext = fileURL.pathExtension.lowercased()

        let candidate: MediaCandidate
        if SourceScannerTraversal.photoExtensions.contains(ext) {
            let metadata = ImageIOPhotoMetadataExtractor().extract(from: fileURL)
            candidate = MediaCandidate(
                absolutePath: fileURL.path,
                relativePath: relativePath,
                mediaType: .photo,
                sizeBytes: 0,
                mtime: Date(),
                photoMetadata: metadata
            )
        } else {
            let metadata = AVFoundationVideoMetadataExtractor().extract(from: fileURL, fallbackMtime: Date())
            candidate = MediaCandidate(
                absolutePath: fileURL.path,
                relativePath: relativePath,
                mediaType: .video,
                sizeBytes: 0,
                mtime: Date(),
                videoMetadata: metadata
            )
        }

        let inference = Self.seededLabeler.infer(for: candidate)
        return LabeledFile(relativePath: relativePath, cameraLabel: inference.cameraLabel)
    }

    /// No-op (not a failure) when the subtree isn't present locally -- this
    /// suite runs against whatever real fixtures happen to be on disk.
    private static func assertKnownMapping(
        _ labeled: [LabeledFile],
        pathFragment: String,
        rawCode: String,
        expectedLabelSubstring: String
    ) {
        let matches = labeled.filter { $0.relativePath.contains(pathFragment) }
        guard !matches.isEmpty else { return }

        for file in matches {
            XCTAssertFalse(
                file.cameraLabel.contains(rawCode),
                "\(file.relativePath) resolved to a label leaking the raw model code: \(file.cameraLabel)"
            )
        }

        XCTAssertTrue(
            matches.contains { $0.cameraLabel.contains(expectedLabelSubstring) },
            "expected at least one file matching '\(pathFragment)' to resolve to a label containing "
                + "'\(expectedLabelSubstring)', got: \(matches.map(\.cameraLabel))"
        )
    }
}
