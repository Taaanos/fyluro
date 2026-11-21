import Foundation
import XCTest
@testable import FyluroCore

/// Speed check against video fixtures under `Tests/TestingDirs`
/// (or `FYLURO_TESTING_FIXTURES`).
/// Coarse thresholds: generous enough to avoid flakiness on a loaded
/// machine, tight enough to catch an accidental full/near-full file read.
final class VideoEmbeddedBoxMetadataResolverBenchmarkTests: XCTestCase {
    private var fixturesRoot: URL!

    override func setUpWithError() throws {
        if let override = ProcessInfo.processInfo.environment["FYLURO_TESTING_FIXTURES"], !override.isEmpty {
            fixturesRoot = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            fixturesRoot = URL(fileURLWithPath: #filePath, isDirectory: false)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("TestingDirs", isDirectory: true)
        }
        guard FileManager.default.fileExists(atPath: fixturesRoot.path) else {
            throw XCTSkip("Fixtures directory not present: \(fixturesRoot.path)")
        }
    }

    /// Headline case: a large real GoPro file (>= 10 MB). The box-walk path
    /// reads tens of KB (moov/udta/GPMF) regardless of file size; the old
    /// blind-scan-only path always reads a fixed ~4MB window and runs ~20
    /// regex patterns over it.
    func testGoProLargeFileBoxWalkIsDramaticallyFasterThanBlindScan() throws {
        let candidatePaths = [
            "SD_CARD2/DCIM/100GOPRO/GX010645.MP4",
            "hero 10/GX010645.MP4",
        ]
        guard let path = candidatePaths
            .map({ fixturesRoot.appendingPathComponent($0) })
            .first(where: { FileManager.default.fileExists(atPath: $0.path) })
        else {
            throw XCTSkip("GoPro fixture not present under \(fixturesRoot.path)")
        }
        let sizeBytes = (try? FileManager.default.attributesOfItem(atPath: path.path)[.size] as? NSNumber)?.int64Value ?? 0
        guard sizeBytes >= 10_000_000 else {
            throw XCTSkip("Large GoPro fixture (>= 10 MB) required for blind-scan speedup benchmark")
        }

        let boxWalkElapsed = Self.elapsed { Self.extract(from: path, vendorAtomDecoders: Self.currentVendorAtomDecoders) }
        let blindScanElapsed = Self.elapsed { Self.extract(from: path, vendorAtomDecoders: [:]) }

        print("GoPro large file: box-walk=\(boxWalkElapsed)s, blind-scan=\(blindScanElapsed)s")

        XCTAssertLessThan(boxWalkElapsed, 0.5, "box-walk path should resolve in well under a second regardless of file size")
        XCTAssertLessThan(boxWalkElapsed, blindScanElapsed, "box-walk path should be faster than the blind scan it replaces")
    }

    /// Zero-overhead-on-miss: a file with no known vendor atom (Insta360's
    /// model lives in a proprietary trailer, not a box) must still fall all
    /// the way through to the blind scan -- the box walk attempted first
    /// should add only negligible overhead (a handful of header reads), not
    /// meaningfully slow down the case it can't help.
    func testFileWithNoKnownVendorAtomIsNotMeaningfullySlowerThanBlindScanAlone() throws {
        let candidatePaths = [
            "SD_CARD2/DCIM/Camera01/VID_20231023_055225_00_645.insv",
            "insta360/VID_20231023_055225_00_645.insv",
        ]
        guard let path = candidatePaths
            .map({ fixturesRoot.appendingPathComponent($0) })
            .first(where: { FileManager.default.fileExists(atPath: $0.path) })
        else {
            throw XCTSkip("Insta360 fixture not present under \(fixturesRoot.path)")
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
            "SD_CARD2/DCIM/100MEDIA/DJI_20260613062714_0010_D.MP4",
            "SD_CARD2/DCIM/CAMERA/20240809_164400.mp4",
            "SD_CARD2/PRIVATE/M4ROOT/CLIP/20250824_C2864.MP4",
            "SD_CARD1/DCIM/IMG_8249.MOV",
            "action-6/DJI_20260613062714_0010_D.MP4",
            "samsung galaxy a54 /20240809_164400.mp4",
            "rx100 mk6/C0014.MP4",
            "iphone 13 pro/IMG_8249.MOV",
        ]

        for relativePath in candidates {
            let path = fixturesRoot.appendingPathComponent(relativePath)
            guard FileManager.default.fileExists(atPath: path.path) else {
                continue
            }
            let elapsed = Self.elapsed { Self.extract(from: path, vendorAtomDecoders: Self.currentVendorAtomDecoders) }
            print("\(relativePath): \(elapsed)s")
            XCTAssertLessThan(elapsed, 1.0, "\(relativePath) took \(elapsed)s")
        }
    }

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
