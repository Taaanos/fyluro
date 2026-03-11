import Foundation
import XCTest
@testable import RollKeepCore

final class AVFoundationVideoMetadataExtractorTests: XCTestCase {
    func testDoesNotRunEmbeddedFallbackWhenPrimaryHasDateAndCameraIdentity() {
        let counter = ThreadSafeCounter()
        let extractor = AVFoundationVideoMetadataExtractor(
            embeddedMetadataExtractor: { _, _ in
                counter.increment()
                return VideoMetadataSnapshot(
                    captureDateTime: Date(timeIntervalSince1970: 100),
                    cameraMake: "FallbackMake",
                    cameraModel: "FallbackModel",
                    cameraSerial: "FallbackSerial"
                )
            }
        )

        let primary = VideoMetadataSnapshot(
            captureDateTime: Date(timeIntervalSince1970: 1_700_000_000),
            cameraMake: "Sony",
            cameraModel: nil,
            cameraSerial: nil
        )
        let resolved = extractor.resolveEmbeddedFallbackIfNeeded(
            primary: primary,
            fileURL: URL(fileURLWithPath: "/tmp/clip.mov")
        )

        XCTAssertEqual(counter.value, 0)
        XCTAssertEqual(resolved.captureDateTime, primary.captureDateTime)
        XCTAssertEqual(resolved.cameraMake, "Sony")
        XCTAssertNil(resolved.cameraModel)
        XCTAssertNil(resolved.cameraSerial)
    }

    func testDoesNotRunEmbeddedFallbackWhenDateMissingButCameraIdentityPresent() {
        let counter = ThreadSafeCounter()
        let extractor = AVFoundationVideoMetadataExtractor(
            embeddedMetadataExtractor: { _, _ in
                counter.increment()
                return VideoMetadataSnapshot(
                    captureDateTime: Date(timeIntervalSince1970: 1_700_123_456),
                    cameraMake: nil,
                    cameraModel: nil,
                    cameraSerial: nil
                )
            }
        )

        let primary = VideoMetadataSnapshot(
            captureDateTime: nil,
            cameraMake: "Sony",
            cameraModel: "FX3",
            cameraSerial: nil
        )
        let resolved = extractor.resolveEmbeddedFallbackIfNeeded(
            primary: primary,
            fileURL: URL(fileURLWithPath: "/tmp/clip.mov")
        )

        XCTAssertEqual(counter.value, 0)
        XCTAssertNil(resolved.captureDateTime)
        XCTAssertEqual(resolved.cameraMake, "Sony")
        XCTAssertEqual(resolved.cameraModel, "FX3")
    }

    func testRunsEmbeddedFallbackWhenDateAndCameraIdentityMissing() {
        let counter = ThreadSafeCounter()
        let fallbackDate = Date(timeIntervalSince1970: 1_700_123_456)
        let extractor = AVFoundationVideoMetadataExtractor(
            embeddedMetadataExtractor: { _, _ in
                counter.increment()
                return VideoMetadataSnapshot(
                    captureDateTime: fallbackDate,
                    cameraMake: "GoPro",
                    cameraModel: "HERO12",
                    cameraSerial: "ABC12345"
                )
            }
        )

        let primary = VideoMetadataSnapshot(
            captureDateTime: nil,
            cameraMake: nil,
            cameraModel: nil,
            cameraSerial: nil
        )
        let resolved = extractor.resolveEmbeddedFallbackIfNeeded(
            primary: primary,
            fileURL: URL(fileURLWithPath: "/tmp/clip.mov")
        )

        XCTAssertEqual(counter.value, 1)
        XCTAssertEqual(resolved.captureDateTime, fallbackDate)
        XCTAssertEqual(resolved.cameraMake, "GoPro")
        XCTAssertEqual(resolved.cameraModel, "HERO12")
        XCTAssertEqual(resolved.cameraSerial, "ABC12345")
    }

    func testRequiresEmbeddedFallbackPolicy() {
        XCTAssertFalse(AVFoundationVideoMetadataExtractor.requiresEmbeddedFallback(
            VideoMetadataSnapshot(captureDateTime: nil, cameraMake: "Sony", cameraModel: nil, cameraSerial: nil)
        ))
        XCTAssertFalse(AVFoundationVideoMetadataExtractor.requiresEmbeddedFallback(
            VideoMetadataSnapshot(captureDateTime: Date(), cameraMake: nil, cameraModel: nil, cameraSerial: nil)
        ))
        XCTAssertTrue(AVFoundationVideoMetadataExtractor.requiresEmbeddedFallback(
            VideoMetadataSnapshot(captureDateTime: nil, cameraMake: nil, cameraModel: nil, cameraSerial: "ABC12345")
        ))
        XCTAssertFalse(AVFoundationVideoMetadataExtractor.requiresEmbeddedFallback(
            VideoMetadataSnapshot(captureDateTime: Date(), cameraMake: "Sony", cameraModel: nil, cameraSerial: nil)
        ))
    }
}

private final class ThreadSafeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = 0

    func increment() {
        lock.lock()
        _value += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        let current = _value
        lock.unlock()
        return current
    }
}
