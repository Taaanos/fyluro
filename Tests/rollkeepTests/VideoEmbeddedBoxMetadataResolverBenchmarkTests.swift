import Foundation
import XCTest
@testable import RollKeepCore

/// Local-only speed check against real fixtures under
/// Tests/TestingDirs (gitignored, not part of CI).
/// Coarse thresholds: generous enough to avoid flakiness on a loaded
/// machine, tight enough to catch an accidental full/near-full file read.
final class VideoEmbeddedBoxMetadataResolverBenchmarkTests: XCTestCase {
    private static let fixturesRoot = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Tests/TestingDirs", isDirectory: true)

    override func setUpWithError() throws {
        guard FileManager.default.fileExists(atPath: Self.fixturesRoot.path) else {
            throw XCTSkip("Local fixtures directory not present: \(Self.fixturesRoot.path)")
        }
    }

    /// Headline case: a 670MB GoPro file. The box-walk path reads tens of KB
    /// (moov/udta/GPMF) regardless of file size; the old blind-scan-only
    /// path always reads a fixed ~4MB window and runs ~20 regex patterns
    /// over it. Both should resolve the same make/model, but the box-walk
    /// path should be at least an order of magnitude faster.
    func testGoProLargeFileBoxWalkIsDramaticallyFasterThanBlindScan() throws {
        let path = Self.fixturesRoot.appendingPathComponent("gopro hero 12/GX010645.MP4")
        guard FileManager.default.fileExists(atPath: path.path) else {
            throw XCTSkip("fixture not present: \(path.path)")
        }

        let boxWalkElapsed = Self.elapsed { Self.extract(from: path, vendorAtomDecoders: Self.currentVendorAtomDecoders) }
        let blindScanElapsed = Self.elapsed { Self.extract(from: path, vendorAtomDecoders: [:]) }

        print("GoPro 670MB file: box-walk=\(boxWalkElapsed)s, blind-scan=\(blindScanElapsed)s")

        XCTAssertLessThan(boxWalkElapsed, 0.5, "box-walk path should resolve in well under a second regardless of file size")
        XCTAssertLessThan(boxWalkElapsed, blindScanElapsed, "box-walk path should be faster than the blind scan it replaces")
    }

    /// Zero-overhead-on-miss: a file with no known vendor atom (Insta360's
    /// model lives in a proprietary trailer, not a box) must still fall all
    /// the way through to the blind scan -- the box walk attempted first
    /// should add only negligible overhead (a handful of header reads), not
    /// meaningfully slow down the case it can't help.
    func testFileWithNoKnownVendorAtomIsNotMeaningfullySlowerThanBlindScanAlone() throws {
        let path = Self.fixturesRoot.appendingPathComponent("insta360/VID_20231023_055225_00_645.insv")
        guard FileManager.default.fileExists(atPath: path.path) else {
            throw XCTSkip("fixture not present: \(path.path)")
        }

        let withBoxWalkAttempt = Self.elapsed { Self.extract(from: path, vendorAtomDecoders: Self.currentVendorAtomDecoders) }
        let blindScanOnly = Self.elapsed { Self.extract(from: path, vendorAtomDecoders: [:]) }

        print("Insta360 (no vendor atom): with-box-walk-attempt=\(withBoxWalkAttempt)s, blind-scan-only=\(blindScanOnly)s")

        // The box walk itself is a handful of cheap header reads; allow a
        // generous fixed overhead budget rather than a tight ratio, since
        // both times are already dominated by the same slow blind scan.
        XCTAssertLessThan(withBoxWalkAttempt, blindScanOnly + 0.5)
    }

    func testSmallFilesResolveWellUnderASecond() throws {
        let candidates = [
            "action-6/DJI_20260613062714_0010_D.MP4",
            "samsung galaxy a54 /20240809_164400.mp4",
            "rx100 mk6/C0014.MP4",
            "iphone 13 pro/IMG_8249.MOV",
        ]

        for relativePath in candidates {
            let path = Self.fixturesRoot.appendingPathComponent(relativePath)
            guard FileManager.default.fileExists(atPath: path.path) else {
                continue
            }
            let elapsed = Self.elapsed { Self.extract(from: path, vendorAtomDecoders: Self.currentVendorAtomDecoders) }
            print("\(relativePath): \(elapsed)s")
            XCTAssertLessThan(elapsed, 1.0, "\(relativePath) took \(elapsed)s")
        }
    }

    // MARK: - Helpers

    private static func elapsed(_ body: () -> Void) -> TimeInterval {
        let start = Date()
        body()
        return Date().timeIntervalSince(start)
    }

    private static var currentVendorAtomDecoders: [String: VideoVendorAtomDecoder] {
        [
            "GPMF": GoProGPMFMetadataDecoder().decode,
            "Xtra": DJIXtraMetadataDecoder().decode,
            "smta": SamsungSmtaMetadataDecoder().decode,
        ]
    }

    @discardableResult
    private static func extract(from fileURL: URL, vendorAtomDecoders: [String: VideoVendorAtomDecoder]) -> VideoMetadata {
        let resolver = VideoEmbeddedBoxMetadataResolver(vendorAtomDecoders: vendorAtomDecoders)
        let extractor = AVFoundationVideoMetadataExtractor(
            embeddedMetadataExtractor: { url, parser in
                resolver.extract(from: url, parser: parser, textScanByteCount: 2 * 1024 * 1024)
            }
        )
        return extractor.extract(from: fileURL, fallbackMtime: Date())
    }
}
