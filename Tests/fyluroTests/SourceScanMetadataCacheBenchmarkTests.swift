import Foundation
import XCTest
@testable import FyluroCore

/// Speed check against video fixtures under `Tests/TestingDirs`
/// (or `FYLURO_TESTING_FIXTURES`), following the same pattern as
/// VideoEmbeddedBoxMetadataResolverBenchmarkTests. Measures the ingest-start
/// win from Finding 1 of docs/audits/performance-audit-2026-07-16.md: a
/// `.deep` scan reusing metadata a preceding `.preview` scan already resolved
/// for known-camera files, versus a cold `.deep` scan with no prior cache.
final class SourceScanMetadataCacheBenchmarkTests: XCTestCase {

    /// Known-vendor video fixtures spanning several formats (GoPro,
    /// DJI, Sony, Apple) that the box-walk resolver can identify -- avoids
    /// insta360, which is deliberately unresolvable via box-walk and would
    /// pollute a known-camera batch with cache-ineligible entries.
    private static let batchRelativePaths = [
        "SD_CARD2/DCIM/100GOPRO/GX010645.MP4",
        "SD_CARD2/DCIM/100GOPRO/GX020024.MP4",
        "SD_CARD2/DCIM/100MEDIA/DJI_20260613062714_0010_D.MP4",
        "SD_CARD2/DCIM/DJI_001/DJI_20260523115257_0565_D.MP4",
        "SD_CARD2/DCIM/DJI_001/DJI_20240126093104_0012_D.MP4",
        "SD_CARD2/PRIVATE/M4ROOT/CLIP/20250824_C2864.MP4",
        "SD_CARD1/DCIM/IMG_8249.MOV",
        "hero 10/GX010645.MP4",
        "hero 10/GX020024.MP4",
        "action-6/DJI_20260613062714_0010_D.MP4",
        "mini-4-pro/DJI_20260523115257_0565_D.MP4",
        "pocket-3/DJI_20240126093104_0012_D.MP4",
        "rx100 mk6/C0014.MP4",
        "iphone 13 pro/IMG_8249.MOV",
    ]

    private var batchRoot: URL!

    override func setUpWithError() throws {
        let fixturesRoot: URL
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

        let unique = "fyluro-cache-benchmark-\(UUID().uuidString.lowercased())"
        batchRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(unique, isDirectory: true)
        try FileManager.default.createDirectory(at: batchRoot, withIntermediateDirectories: true)

        // Hard-link (not copy) each present fixture into an isolated batch
        // directory: instant, no extra disk usage, identical bytes/inode, so
        // metadata resolution behaves exactly as it would against the
        // original file.
        var linkedAny = false
        for relativePath in Self.batchRelativePaths {
            let source = fixturesRoot.appendingPathComponent(relativePath)
            guard FileManager.default.fileExists(atPath: source.path) else {
                continue
            }
            let destination = batchRoot.appendingPathComponent((relativePath as NSString).lastPathComponent)
            if (try? FileManager.default.linkItem(at: source, to: destination)) != nil {
                linkedAny = true
            }
        }
        guard linkedAny else {
            throw XCTSkip("None of the expected fixture files are present under \(fixturesRoot.path)")
        }
    }

    override func tearDownWithError() throws {
        if let batchRoot {
            try? FileManager.default.removeItem(at: batchRoot)
        }
    }

    /// Headline case: known-camera files resolved during preview should be
    /// reused outright at ingest start instead of re-opening and
    /// re-parsing each container from scratch.
    func testCacheWarmedDeepScanIsFasterThanColdDeepScanForKnownCameraBatch() throws {
        let coldElapsed = Self.elapsed {
            _ = try? SourceScanner().scan(sourceRoot: batchRoot, mode: .deep)
        }

        let cache = InMemorySourceScanMetadataCache()
        _ = try SourceScanner().scan(sourceRoot: batchRoot, mode: .preview, metadataCache: cache)

        let warmElapsed = Self.elapsed {
            _ = try? SourceScanner().scan(sourceRoot: batchRoot, mode: .deep, metadataCache: cache)
        }

        print("known-camera batch (\(Self.batchRelativePaths.count) candidates): cold deep=\(coldElapsed)s, cache-warmed deep=\(warmElapsed)s")

        XCTAssertLessThan(warmElapsed, coldElapsed, "a cache-warmed deep scan should be faster than a cold one for known-camera files")
        // Generous ceiling, not a tight ratio: real machine load varies, but
        // a warmed scan skipping AVFoundation/box-walk entirely for every
        // known-camera candidate should complete in well under a second
        // regardless of how large the underlying video files are.
        XCTAssertLessThan(warmElapsed, 1.0, "cache-warmed deep scan took \(warmElapsed)s")
    }

    /// Compute-neutrality check for the preview side (requirement #6 of the
    /// caching design): preview already resolves this same per-file data
    /// today to compute the live camera-distribution stats, so retaining it
    /// in a cache should add no meaningful new cost. Looser assertion than
    /// the ingest-start case above -- this is confirming "no regression,"
    /// not measuring a speedup.
    func testPreviewPassWithCachingIsNotMeaningfullySlowerThanWithoutIt() throws {
        let withoutCache = Self.elapsed {
            _ = try? SourceScanner().scan(sourceRoot: batchRoot, mode: .preview)
        }
        let withCache = Self.elapsed {
            _ = try? SourceScanner().scan(sourceRoot: batchRoot, mode: .preview, metadataCache: InMemorySourceScanMetadataCache())
        }

        print("preview pass: without cache=\(withoutCache)s, with cache=\(withCache)s")

        XCTAssertLessThan(withCache, withoutCache + 0.5, "populating the cache during preview should not add meaningful overhead")
    }

    // MARK: - Helpers

    private static func elapsed(_ body: () -> Void) -> TimeInterval {
        let start = Date()
        body()
        return Date().timeIntervalSince(start)
    }
}
