import Foundation
import XCTest
@testable import RollKeepCore

/// End-to-end camera-*labeling* regression sweep across every real photo and
/// video fixture under Tests/TestingDirs -- a
/// local-only, gitignored directory of real camera media, not part of CI
/// (see scripts/build-e2e-fixtures.py).
///
/// `CameraMetadataFixtureRegressionTests` already covers raw make/model/
/// serial extraction for videos, but stops before `CameraLabeler` --
/// it never exercises `CameraIdentityLabelNormalizer`'s model-code lookup.
/// This test drives the full photo+video pipeline through to the folder
/// label, so a regression in the model-code catalog (e.g. after moving it
/// from a hardcoded dict to JSON resource files) shows up here even though
/// the box-walk-level test would stay green.
final class CameraLabelFixtureRegressionTests: XCTestCase {
    private struct LabeledFile {
        let relativePath: String
        let cameraLabel: String
    }

    private static let fixturesRoot = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Tests/TestingDirs", isDirectory: true)

    func testLabelsAcrossRealFixturesReportAndKnownMappingsHold() throws {
        guard FileManager.default.fileExists(atPath: Self.fixturesRoot.path) else {
            throw XCTSkip("Local fixtures directory not present: \(Self.fixturesRoot.path)")
        }

        let mediaFiles = try Self.discoverMediaFiles()
        guard !mediaFiles.isEmpty else {
            throw XCTSkip("No photo/video fixtures found under \(Self.fixturesRoot.path)")
        }

        let labeled = mediaFiles
            .map(Self.label(fileURL:))
            .sorted { $0.relativePath < $1.relativePath }

        // Printed for manual before/after diffing across the refactor: run
        // on main, save the output, run again on the branch, diff -- must
        // be empty since behavior is meant to stay identical.
        print(labeled.map { "\($0.relativePath) -> \($0.cameraLabel)" }.joined(separator: "\n"))

        // The raw-code-never-leaks invariant is more robust than an exact
        // before/after diff to hand-maintain here: it holds regardless of
        // which fixtures happen to be present locally, and directly proves
        // the model-code catalog is doing its job for every vendor with a
        // known mapping.
        Self.assertKnownMapping(
            labeled, subtreePrefix: "mini-4-pro/", rawCode: "fc8482", expectedLabelSubstring: "mini4-pro"
        )
        Self.assertKnownMapping(
            labeled, subtreePrefix: "pocket-3/", rawCode: "pp-101", expectedLabelSubstring: "osmopocket3"
        )
        Self.assertKnownMapping(
            labeled, subtreePrefix: "samsung galaxy a54", rawCode: "sm-a546b", expectedLabelSubstring: "galaxy-a54-5g"
        )
        Self.assertKnownMapping(
            labeled, subtreePrefix: "action-4/", rawCode: "ac003", expectedLabelSubstring: "osmoaction4"
        )
        Self.assertKnownMapping(
            labeled, subtreePrefix: "action-6/", rawCode: "ac006", expectedLabelSubstring: "osmoaction6"
        )
    }

    private static func discoverMediaFiles() throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: fixturesRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var results: [URL] = []
        while let url = enumerator.nextObject() as? URL {
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

    private static func label(fileURL: URL) -> LabeledFile {
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

        let inference = CameraLabeler().infer(for: candidate)
        return LabeledFile(relativePath: relativePath, cameraLabel: inference.cameraLabel)
    }

    /// No-op (not a failure) when the subtree isn't present locally -- this
    /// suite runs against whatever real fixtures happen to be on disk.
    private static func assertKnownMapping(
        _ labeled: [LabeledFile],
        subtreePrefix: String,
        rawCode: String,
        expectedLabelSubstring: String
    ) {
        let matches = labeled.filter { $0.relativePath.hasPrefix(subtreePrefix) }
        guard !matches.isEmpty else { return }

        for file in matches {
            XCTAssertFalse(
                file.cameraLabel.contains(rawCode),
                "\(file.relativePath) resolved to a label leaking the raw model code: \(file.cameraLabel)"
            )
        }

        XCTAssertTrue(
            matches.contains { $0.cameraLabel.contains(expectedLabelSubstring) },
            "expected at least one file under \(subtreePrefix) to resolve to a label containing "
                + "'\(expectedLabelSubstring)', got: \(matches.map(\.cameraLabel))"
        )
    }
}
