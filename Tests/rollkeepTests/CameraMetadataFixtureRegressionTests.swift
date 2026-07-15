import Foundation
import XCTest
@testable import RollKeepCore

/// Compares "new" (box-walk vendor decoders enabled) vs "old" (box-walk
/// disabled, pure AVFoundation + sidecar + heuristic text-scan fallback)
/// camera identification across every real video fixture under
/// Tests/TestingDirs -- a local-only, gitignored
/// directory of real camera media, not part of CI (see
/// scripts/build-e2e-fixtures.py, which sources the repo's own e2e fixture
/// cards from the same directory).
///
/// This is the project's standing regression tool for this area: rerun it
/// whenever adding a new vendor decoder to confirm zero regressions against
/// real files before considering the change done.
final class CameraMetadataFixtureRegressionTests: XCTestCase {
    private struct CameraFields {
        let make: String?
        let model: String?
        let serial: String?
    }

    private static let fixturesRoot = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Tests/TestingDirs", isDirectory: true)
    private static let videoExtensions: Set<String> = ["mov", "mp4", "m4v", "insv"]

    func testNoRegressionsAcrossRealVideoFixtures() throws {
        guard FileManager.default.fileExists(atPath: Self.fixturesRoot.path) else {
            throw XCTSkip("Local fixtures directory not present: \(Self.fixturesRoot.path)")
        }

        let videoFiles = try Self.discoverVideoFiles()
        guard !videoFiles.isEmpty else {
            throw XCTSkip("No video fixtures found under \(Self.fixturesRoot.path)")
        }

        var regressions: [String] = []
        var report: [String] = []

        for fileURL in videoFiles {
            let relativePath = fileURL.path.replacingOccurrences(of: Self.fixturesRoot.path + "/", with: "")

            let oldFields = Self.extract(from: fileURL, vendorAtomDecoders: [:])
            let newFields = Self.extract(from: fileURL, vendorAtomDecoders: Self.currentVendorAtomDecoders)

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

    private static func discoverVideoFiles() throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: fixturesRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var results: [URL] = []
        while let url = enumerator.nextObject() as? URL {
            if videoExtensions.contains(url.pathExtension.lowercased()) {
                results.append(url)
            }
        }
        return results.sorted { $0.path < $1.path }
    }

    private static var currentVendorAtomDecoders: [String: VideoVendorAtomDecoder] {
        [
            "GPMF": GoProGPMFMetadataDecoder().decode,
            "Xtra": DJIXtraMetadataDecoder().decode,
            "smta": SamsungSmtaMetadataDecoder().decode,
        ]
    }

    private static func extract(from fileURL: URL, vendorAtomDecoders: [String: VideoVendorAtomDecoder]) -> CameraFields {
        let resolver = VideoEmbeddedBoxMetadataResolver(vendorAtomDecoders: vendorAtomDecoders)
        let extractor = AVFoundationVideoMetadataExtractor(
            embeddedMetadataExtractor: { url, parser in
                resolver.extract(from: url, parser: parser, textScanByteCount: 2 * 1024 * 1024)
            }
        )
        let metadata = extractor.extract(from: fileURL, fallbackMtime: Date())
        return CameraFields(make: metadata.cameraMake, model: metadata.cameraModel, serial: metadata.cameraSerial)
    }
}
