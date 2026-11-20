import Foundation
import XCTest
@testable import FyluroCore

final class VideoMetadataFallbackResolverTests: XCTestCase {
    func testSidecarFallbackSkipsExtractorWhenPrimaryIsComplete() {
        let counter = Counter()
        let resolver = VideoMetadataFallbackResolver(
            embeddedFallbackMode: .full,
            parser: VideoCreationDateParser(),
            sidecarMetadataExtractor: { _, _ in
                counter.increment()
                return VideoMetadataSnapshot(
                    captureDateTime: Date(timeIntervalSince1970: 1_700_123_456),
                    captureDateSource: .sidecarMetadata,
                    cameraMake: "Canon",
                    cameraModel: "EOS R5",
                    cameraSerial: "1234"
                )
            },
            embeddedMetadataExtractor: { _, _ in
                XCTFail("Embedded extractor should not be called by sidecar-only resolution")
                return VideoMetadataSnapshot(
                    captureDateTime: nil,
                    captureDateSource: nil,
                    cameraMake: nil,
                    cameraModel: nil,
                    cameraSerial: nil
                )
            }
        )

        let primary = VideoMetadataSnapshot(
            captureDateTime: Date(timeIntervalSince1970: 1_700_000_001),
            captureDateSource: .creationTime,
            cameraMake: "Sony",
            cameraModel: "FX3",
            cameraSerial: "ABCD"
        )
        let resolved = resolver.resolveSidecarFallbackIfNeeded(
            primary: primary,
            fileURL: URL(fileURLWithPath: "/tmp/clip.mp4")
        )

        XCTAssertEqual(counter.value, 0)
        XCTAssertEqual(resolved.captureDateTime, primary.captureDateTime)
        XCTAssertEqual(resolved.cameraMake, primary.cameraMake)
        XCTAssertEqual(resolved.cameraModel, primary.cameraModel)
        XCTAssertEqual(resolved.cameraSerial, primary.cameraSerial)
    }

    func testEmbeddedFallbackMergesMissingCameraFieldsWithoutOverwritingPrimaryDate() {
        let resolver = VideoMetadataFallbackResolver(
            embeddedFallbackMode: .full,
            parser: VideoCreationDateParser(),
            sidecarMetadataExtractor: { _, _ in
                VideoMetadataSnapshot(
                    captureDateTime: nil,
                    captureDateSource: nil,
                    cameraMake: nil,
                    cameraModel: nil,
                    cameraSerial: nil
                )
            },
            embeddedMetadataExtractor: { _, _ in
                VideoMetadataSnapshot(
                    captureDateTime: Date(timeIntervalSince1970: 1_700_111_111),
                    captureDateSource: .creationTime,
                    cameraMake: "DJI",
                    cameraModel: "Mini4 Pro",
                    cameraSerial: nil
                )
            }
        )

        let primary = VideoMetadataSnapshot(
            captureDateTime: Date(timeIntervalSince1970: 1_700_999_999),
            captureDateSource: .creationTime,
            cameraMake: nil,
            cameraModel: nil,
            cameraSerial: nil
        )
        let resolved = resolver.resolveEmbeddedFallbackIfNeeded(
            primary: primary,
            fileURL: URL(fileURLWithPath: "/tmp/clip.mp4")
        )

        XCTAssertEqual(resolved.captureDateTime, primary.captureDateTime)
        XCTAssertEqual(resolved.cameraMake, "DJI")
        XCTAssertEqual(resolved.cameraModel, "Mini4 Pro")
        XCTAssertEqual(resolved.cameraSerial, nil)
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var current = 0

    func increment() {
        lock.lock()
        current += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        let value = current
        lock.unlock()
        return value
    }
}
