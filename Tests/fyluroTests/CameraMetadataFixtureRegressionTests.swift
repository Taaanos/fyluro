import Foundation
import XCTest
@testable import FyluroCore

/// Compares "new" (box-walk vendor decoders enabled) vs "old" (box-walk
/// disabled, pure AVFoundation + sidecar + heuristic text-scan fallback)
/// camera identification across every video fixture under
/// `Tests/TestingDirs` (or `FYLURO_TESTING_FIXTURES`).
///
/// This is the project's standing regression tool for this area: rerun it
/// whenever adding a new vendor decoder to confirm zero regressions before
/// considering the change done.
final class CameraMetadataFixtureRegressionTests: XCTestCase {
    private struct CameraFields {
        let make: String?
        let model: String?
        let serial: String?
    }

    private static var fixturesRoot: URL {
        if let override = ProcessInfo.processInfo.environment["FYLURO_TESTING_FIXTURES"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return URL(fileURLWithPath: #filePath, isDirectory: false)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("TestingDirs", isDirectory: true)
    }
    private static let videoExtensions: Set<String> = ["mov", "mp4", "m4v", "insv"]

    func testNoRegressionsAcrossRealVideoFixtures() throws {
        let fixturesRoot = Self.fixturesRoot
        guard FileManager.default.fileExists(atPath: fixturesRoot.path) else {
            throw XCTSkip("Fixtures directory not present: \(fixturesRoot.path)")
        }

        let videoFiles = try Self.discoverVideoFiles(under: fixturesRoot)
        guard !videoFiles.isEmpty else {
            throw XCTSkip("No video fixtures found under \(fixturesRoot.path)")
        }

        var regressions: [String] = []
        var report: [String] = []

        for fileURL in videoFiles {
            let relativePath = fileURL.path.replacingOccurrences(of: fixturesRoot.path + "/", with: "")

            let oldFields = Self.extract(from: fileURL, useProductionDecoders: false)
            let newFields = Self.extract(from: fileURL, useProductionDecoders: true)

            let oldKnown = oldFields.make != nil || oldFields.model != nil
            let newKnown = newFields.make != nil || newFields.model != nil

            if oldKnown, !newKnown {
                regressions.append(
                    "\(relativePath): REGRESSED known->unknown "
                        + "(was make=\(oldFields.make ?? "nil") model=\(oldFields.model ?? "nil"))"
                )
            } else if oldKnown, newKnown,
                      let oldModel = oldFields.model, let newModel = newFields.model,
                      oldModel != newModel,
                      !newModel.localizedCaseInsensitiveContains(oldModel),
                      !oldModel.localizedCaseInsensitiveContains(newModel)
            {
                // Both resolved, but to values that don't even overlap as
                // substrings of one another -- e.g. a terse code that's
                // literally contained in a friendlier name is fine and
                // expected (see VideoEmbeddedBoxMetadataResolver's
                // friendlier-model lookup); two unrelated strings are not.
                regressions.append(
                    "\(relativePath): MODEL CHANGED old='\(oldModel)' new='\(newModel)' (unrelated strings)"
                )
            }

            report.append(
                "\(relativePath): "
                    + "old(make=\(oldFields.make ?? "nil"), model=\(oldFields.model ?? "nil"), serial=\(oldFields.serial ?? "nil")) -> "
                    + "new(make=\(newFields.make ?? "nil"), model=\(newFields.model ?? "nil"), serial=\(newFields.serial ?? "nil"))"
            )
        }

        print(report.joined(separator: "\n"))

        XCTAssertTrue(regressions.isEmpty, "Found regressions:\n" + regressions.joined(separator: "\n"))
    }

    private static func discoverVideoFiles(under fixturesRoot: URL) throws -> [URL] {
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
            if videoExtensions.contains(url.pathExtension.lowercased()) {
                results.append(url)
            }
        }
        return results.sorted { $0.path < $1.path }
    }

    private static func extract(from fileURL: URL, useProductionDecoders: Bool) -> CameraFields {
        let resolver = useProductionDecoders
            ? VideoEmbeddedBoxMetadataResolver(
                vendorAtomDecoders: AVFoundationVideoMetadataExtractor.vendorAtomDecoders,
                directTagDecoders: AVFoundationVideoMetadataExtractor.directTagDecoders,
                moovUUIDDecoders: AVFoundationVideoMetadataExtractor.moovUUIDDecoders,
                udtaUUIDDecoders: AVFoundationVideoMetadataExtractor.udtaUUIDDecoders
            )
            : VideoEmbeddedBoxMetadataResolver()
        let extractor = AVFoundationVideoMetadataExtractor(
            embeddedMetadataExtractor: { url, parser in
                resolver.extract(from: url, parser: parser, textScanByteCount: 2 * 1024 * 1024)
            }
        )
        let metadata = extractor.extract(from: fileURL, fallbackMtime: Date())
        return CameraFields(make: metadata.cameraMake, model: metadata.cameraModel, serial: metadata.cameraSerial)
    }
}
