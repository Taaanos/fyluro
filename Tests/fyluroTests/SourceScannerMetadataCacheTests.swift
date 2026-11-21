import Foundation
import XCTest
@testable import FyluroCore

final class SourceScannerMetadataCacheTests: XCTestCase {
    private var tempRoot: URL!

    override func setUpWithError() throws {
        let unique = "fyluro-cache-tests-\(UUID().uuidString.lowercased())"
        tempRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(unique, isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
    }

    func testCacheHitReusesIdenticalMetadataAndSkipsRealExtractor() throws {
        try createFile(path: "PRIVATE/clip.MP4", bytes: 123)

        let previewExtractor = FixedVideoMetadataExtractor(
            captureDateTime: Date(timeIntervalSince1970: 1_704_200_010),
            captureDateSource: .creationTime,
            usedFallback: false,
            cameraMake: "Sony",
            cameraModel: "FX3",
            cameraSerial: "12345678"
        )
        let previewScanner = SourceScanner(
            photoMetadataExtractor: StubPhotoMetadataExtractor(metadataByFilename: [:]),
            videoMetadataExtractor: previewExtractor,
            previewVideoMetadataExtractor: previewExtractor
        )
        let cache = InMemorySourceScanMetadataCache()
        let previewSummary = try previewScanner.scan(sourceRoot: tempRoot, mode: .preview, metadataCache: cache)
        let previewMetadata = try XCTUnwrap(previewSummary.candidates.first?.videoMetadata)

        // The deep-pass extractor would produce visibly different metadata if
        // it were ever actually invoked, so any leakage is easy to catch.
        let deepExtractor = CountingVideoMetadataExtractor()
        let deepScanner = SourceScanner(
            photoMetadataExtractor: StubPhotoMetadataExtractor(metadataByFilename: [:]),
            videoMetadataExtractor: deepExtractor
        )
        let deepSummary = try deepScanner.scan(sourceRoot: tempRoot, mode: .deep, metadataCache: cache)
        let deepMetadata = try XCTUnwrap(deepSummary.candidates.first?.videoMetadata)

        XCTAssertEqual(deepExtractor.callCount, 0, "cache hit should skip the real deep extractor entirely")
        XCTAssertEqual(deepMetadata, previewMetadata)
    }

    func testUnknownCameraVideoIsStillReassessedByDeepScan() throws {
        try createFile(path: "PRIVATE/clip.MP4", bytes: 123)

        let previewExtractor = FixedVideoMetadataExtractor(
            captureDateTime: Date(timeIntervalSince1970: 1_704_200_010),
            captureDateSource: .mtimeFallback,
            usedFallback: true,
            cameraMake: nil,
            cameraModel: nil,
            cameraSerial: nil
        )
        let previewScanner = SourceScanner(
            photoMetadataExtractor: StubPhotoMetadataExtractor(metadataByFilename: [:]),
            videoMetadataExtractor: previewExtractor,
            previewVideoMetadataExtractor: previewExtractor
        )
        let cache = InMemorySourceScanMetadataCache()
        _ = try previewScanner.scan(sourceRoot: tempRoot, mode: .preview, metadataCache: cache)

        let deepExtractor = CountingVideoMetadataExtractor()
        let deepScanner = SourceScanner(
            photoMetadataExtractor: StubPhotoMetadataExtractor(metadataByFilename: [:]),
            videoMetadataExtractor: deepExtractor
        )
        let deepSummary = try deepScanner.scan(sourceRoot: tempRoot, mode: .deep, metadataCache: cache)
        let deepMetadata = try XCTUnwrap(deepSummary.candidates.first?.videoMetadata)

        XCTAssertEqual(deepExtractor.callCount, 1, "an unknown-camera cache entry must not be reused")
        XCTAssertEqual(deepMetadata.cameraMake, "Sony")
        XCTAssertEqual(deepMetadata.cameraModel, "FX3")
    }

    /// Guards the bug a partial gate-relax (
    /// `VideoMetadataFallbackResolver.requiresEmbeddedFallback` widened from
    /// `make == nil && model == nil` to `||`) opened here: a file where only
    /// ONE of make/model resolved during preview still has a live chance of
    /// the OTHER field resolving under a `.full` deep scan's text-scan step,
    /// which never runs in `.structuredOnly` preview mode. Reusing such a
    /// snapshot would silently freeze the file at its preview-scan result,
    /// permanently losing whatever the deep scan would have found.
    func testPartiallyKnownCameraVideoIsStillReassessedByDeepScan() throws {
        try createFile(path: "PRIVATE/clip.MP4", bytes: 123)

        let previewExtractor = FixedVideoMetadataExtractor(
            captureDateTime: Date(timeIntervalSince1970: 1_704_200_010),
            captureDateSource: .creationTime,
            usedFallback: false,
            cameraMake: "Sony", // resolved during preview
            cameraModel: nil, // NOT resolved during preview -- only .full's text scan could find it
            cameraSerial: nil
        )
        let previewScanner = SourceScanner(
            photoMetadataExtractor: StubPhotoMetadataExtractor(metadataByFilename: [:]),
            videoMetadataExtractor: previewExtractor,
            previewVideoMetadataExtractor: previewExtractor
        )
        let cache = InMemorySourceScanMetadataCache()
        let previewSummary = try previewScanner.scan(sourceRoot: tempRoot, mode: .preview, metadataCache: cache)
        XCTAssertEqual(previewSummary.candidates.first?.videoMetadata?.cameraMake, "Sony")
        XCTAssertNil(previewSummary.candidates.first?.videoMetadata?.cameraModel)

        let deepExtractor = CountingVideoMetadataExtractor()
        let deepScanner = SourceScanner(
            photoMetadataExtractor: StubPhotoMetadataExtractor(metadataByFilename: [:]),
            videoMetadataExtractor: deepExtractor
        )
        let deepSummary = try deepScanner.scan(sourceRoot: tempRoot, mode: .deep, metadataCache: cache)
        let deepMetadata = try XCTUnwrap(deepSummary.candidates.first?.videoMetadata)

        XCTAssertEqual(deepExtractor.callCount, 1, "a partially-known cache entry (one field still nil) must not be reused")
        XCTAssertEqual(deepMetadata.cameraMake, "Sony")
        XCTAssertEqual(deepMetadata.cameraModel, "FX3")
    }

    func testChangedFileIsTreatedAsCacheMiss() throws {
        let fileURL = try createFile(path: "PRIVATE/clip.MP4", bytes: 123)

        let previewExtractor = FixedVideoMetadataExtractor(
            captureDateTime: Date(timeIntervalSince1970: 1_704_200_010),
            captureDateSource: .creationTime,
            usedFallback: false,
            cameraMake: "Sony",
            cameraModel: "FX3",
            cameraSerial: "12345678"
        )
        let previewScanner = SourceScanner(
            photoMetadataExtractor: StubPhotoMetadataExtractor(metadataByFilename: [:]),
            videoMetadataExtractor: previewExtractor,
            previewVideoMetadataExtractor: previewExtractor
        )
        let cache = InMemorySourceScanMetadataCache()
        _ = try previewScanner.scan(sourceRoot: tempRoot, mode: .preview, metadataCache: cache)

        try Data(repeating: 0x42, count: 456).write(to: fileURL)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_800_000_000)],
            ofItemAtPath: fileURL.path
        )

        let deepExtractor = CountingVideoMetadataExtractor()
        let deepScanner = SourceScanner(
            photoMetadataExtractor: StubPhotoMetadataExtractor(metadataByFilename: [:]),
            videoMetadataExtractor: deepExtractor
        )
        _ = try deepScanner.scan(sourceRoot: tempRoot, mode: .deep, metadataCache: cache)

        XCTAssertEqual(deepExtractor.callCount, 1, "a changed file must not be served from a stale cache entry")
    }

    func testKnownCameraPhotoIsReusedUnconditionally() throws {
        try createFile(path: "DCIM/100MEDIA/IMG_0001.JPG", bytes: 10)

        let previewPhotoExtractor = FixedPhotoMetadataExtractor(
            captureDateTime: Date(timeIntervalSince1970: 1_704_200_000),
            captureDateSource: .dateTimeOriginal,
            cameraMake: "Canon",
            cameraModel: "EOS R5",
            cameraSerial: "999"
        )
        let previewScanner = SourceScanner(photoMetadataExtractor: previewPhotoExtractor)
        let cache = InMemorySourceScanMetadataCache()
        let previewSummary = try previewScanner.scan(sourceRoot: tempRoot, mode: .preview, metadataCache: cache)
        let previewMetadata = try XCTUnwrap(previewSummary.candidates.first?.photoMetadata)

        let deepPhotoExtractor = CountingPhotoMetadataExtractor()
        let deepScanner = SourceScanner(photoMetadataExtractor: deepPhotoExtractor)
        let deepSummary = try deepScanner.scan(sourceRoot: tempRoot, mode: .deep, metadataCache: cache)
        let deepMetadata = try XCTUnwrap(deepSummary.candidates.first?.photoMetadata)

        XCTAssertEqual(deepPhotoExtractor.callCount, 0, "photos have no mode-dependent tier, so any cache hit is reusable")
        XCTAssertEqual(deepMetadata, previewMetadata)
    }

    func testForcedMissingCaptureDatePathBypassesCacheEvenOnFingerprintMatch() throws {
        try createFile(path: "DCIM/100MEDIA/IMG_0001.JPG", bytes: 10)

        // A preview scan never has this override populated -- it resolves and
        // caches a normal, non-nil capture date, exactly like production.
        let previewPhotoExtractor = FixedPhotoMetadataExtractor(
            captureDateTime: Date(timeIntervalSince1970: 1_704_200_000),
            captureDateSource: .dateTimeOriginal,
            cameraMake: "Canon",
            cameraModel: "EOS R5",
            cameraSerial: "999"
        )
        let previewScanner = SourceScanner(photoMetadataExtractor: previewPhotoExtractor)
        let cache = InMemorySourceScanMetadataCache()
        _ = try previewScanner.scan(sourceRoot: tempRoot, mode: .preview, metadataCache: cache)

        let deepScanner = SourceScanner(
            photoMetadataExtractor: previewPhotoExtractor,
            forcedMissingCaptureDateRelativePaths: ["DCIM/100MEDIA/IMG_0001.JPG"]
        )
        let deepSummary = try deepScanner.scan(sourceRoot: tempRoot, mode: .deep, metadataCache: cache)
        let deepMetadata = try XCTUnwrap(deepSummary.candidates.first?.photoMetadata)

        XCTAssertNil(deepMetadata.captureDateTime, "the forced-missing hook must win over a matching cache entry")
        XCTAssertEqual(deepMetadata.captureDateSource, .missing)
    }

    func testNilMetadataCacheBehavesLikeNoCaching() throws {
        try createFile(path: "PRIVATE/clip.MP4", bytes: 123)

        let extractor = CountingVideoMetadataExtractor()
        let scanner = SourceScanner(
            photoMetadataExtractor: StubPhotoMetadataExtractor(metadataByFilename: [:]),
            videoMetadataExtractor: extractor
        )

        _ = try scanner.scan(sourceRoot: tempRoot, mode: .deep, metadataCache: nil)
        _ = try scanner.scan(sourceRoot: tempRoot, mode: .deep, metadataCache: nil)

        XCTAssertEqual(extractor.callCount, 2, "omitting the cache must resolve every file on every scan, as before")
    }

    @discardableResult
    private func createFile(path: String, bytes: Int) throws -> URL {
        let fileURL = tempRoot.appendingPathComponent(path, isDirectory: false)
        let dirURL = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)

        let data = Data(repeating: 0x41, count: bytes)
        FileManager.default.createFile(atPath: fileURL.path, contents: data)
        return fileURL
    }
}

private struct StubPhotoMetadataExtractor: PhotoMetadataExtracting {
    let metadataByFilename: [String: PhotoMetadata]

    func extract(from fileURL: URL) -> PhotoMetadata {
        metadataByFilename[fileURL.lastPathComponent] ?? PhotoMetadata(
            captureDateTime: nil,
            captureDateSource: .missing,
            cameraMake: nil,
            cameraModel: nil,
            cameraSerial: nil
        )
    }
}

private struct FixedPhotoMetadataExtractor: PhotoMetadataExtracting {
    let captureDateTime: Date?
    let captureDateSource: PhotoCaptureDateSource
    let cameraMake: String?
    let cameraModel: String?
    let cameraSerial: String?

    func extract(from fileURL: URL) -> PhotoMetadata {
        PhotoMetadata(
            captureDateTime: captureDateTime,
            captureDateSource: captureDateSource,
            cameraMake: cameraMake,
            cameraModel: cameraModel,
            cameraSerial: cameraSerial
        )
    }
}

private final class CountingPhotoMetadataExtractor: PhotoMetadataExtracting {
    private(set) var callCount = 0

    func extract(from fileURL: URL) -> PhotoMetadata {
        callCount += 1
        return PhotoMetadata(
            captureDateTime: Date(timeIntervalSince1970: 1_600_000_000),
            captureDateSource: .dateTimeOriginal,
            cameraMake: "Nikon",
            cameraModel: "Z9",
            cameraSerial: "777"
        )
    }
}

private struct FixedVideoMetadataExtractor: VideoMetadataExtracting {
    let captureDateTime: Date
    let captureDateSource: VideoCaptureDateSource
    let usedFallback: Bool
    let cameraMake: String?
    let cameraModel: String?
    let cameraSerial: String?

    func extract(from fileURL: URL, fallbackMtime: Date) -> VideoMetadata {
        VideoMetadata(
            captureDateTime: captureDateTime,
            captureDateSource: captureDateSource,
            usedFallback: usedFallback,
            cameraMake: cameraMake,
            cameraModel: cameraModel,
            cameraSerial: cameraSerial
        )
    }
}

private final class CountingVideoMetadataExtractor: VideoMetadataExtracting {
    private(set) var callCount = 0

    func extract(from fileURL: URL, fallbackMtime: Date) -> VideoMetadata {
        callCount += 1
        return VideoMetadata(
            captureDateTime: fallbackMtime.addingTimeInterval(10),
            captureDateSource: .creationTime,
            usedFallback: false,
            cameraMake: "Sony",
            cameraModel: "FX3",
            cameraSerial: "12345678"
        )
    }
}
