import Foundation
import XCTest
@testable import RollKeepCore

final class AVFoundationVideoMetadataExtractorTests: XCTestCase {
    func testSidecarFallbackFillsMissingPrimaryMetadata() {
        let extractor = AVFoundationVideoMetadataExtractor(
            sidecarMetadataExtractor: { _, _ in
                VideoMetadataSnapshot(
                    captureDateTime: Date(timeIntervalSince1970: 1_700_222_333),
                    captureDateSource: .sidecarMetadata,
                    cameraMake: "Canon",
                    cameraModel: "Canon EOS 5D Mark II",
                    cameraSerial: "0123456789",
                    cameraMakeSource: .sidecarMetadataMake,
                    cameraModelSource: .sidecarMetadataModel,
                    cameraSerialSource: .sidecarMetadataSerial,
                    cameraMakeSelectionRule: "sidecar_direct",
                    cameraModelSelectionRule: "sidecar_direct",
                    cameraSerialSelectionRule: "sidecar_direct"
                )
            },
            embeddedMetadataExtractor: { _, _ in
                XCTFail("Embedded fallback should not run when sidecar already resolved date+camera")
                return VideoMetadataSnapshot(
                    captureDateTime: nil,
                    cameraMake: nil,
                    cameraModel: nil,
                    cameraSerial: nil
                )
            }
        )

        let primary = VideoMetadataSnapshot(
            captureDateTime: nil,
            cameraMake: nil,
            cameraModel: nil,
            cameraSerial: nil
        )

        let resolved = extractor.resolveSidecarFallbackIfNeeded(
            primary: primary,
            fileURL: URL(fileURLWithPath: "/tmp/MVI_8241.MOV")
        )

        XCTAssertEqual(resolved.captureDateSource, .sidecarMetadata)
        XCTAssertEqual(resolved.cameraMake, "Canon")
        XCTAssertEqual(resolved.cameraModel, "Canon EOS 5D Mark II")
        XCTAssertEqual(resolved.cameraSerial, "0123456789")
        XCTAssertEqual(resolved.cameraMakeSource, .sidecarMetadataMake)
        XCTAssertEqual(resolved.cameraModelSource, .sidecarMetadataModel)
        XCTAssertEqual(resolved.cameraSerialSource, .sidecarMetadataSerial)
    }

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

    func testRunsEmbeddedFallbackWhenDatePresentButCameraIdentityMissing() {
        let counter = ThreadSafeCounter()
        let primaryDate = Date(timeIntervalSince1970: 1_700_987_654)
        let extractor = AVFoundationVideoMetadataExtractor(
            embeddedMetadataExtractor: { _, _ in
                counter.increment()
                return VideoMetadataSnapshot(
                    captureDateTime: Date(timeIntervalSince1970: 1_700_111_111),
                    cameraMake: "DJI",
                    cameraModel: "DJI Mini4 Pro",
                    cameraSerial: nil
                )
            }
        )

        let primary = VideoMetadataSnapshot(
            captureDateTime: primaryDate,
            cameraMake: nil,
            cameraModel: nil,
            cameraSerial: nil
        )
        let resolved = extractor.resolveEmbeddedFallbackIfNeeded(
            primary: primary,
            fileURL: URL(fileURLWithPath: "/tmp/clip.mp4")
        )

        XCTAssertEqual(counter.value, 1)
        XCTAssertEqual(resolved.captureDateTime, primaryDate)
        XCTAssertEqual(resolved.cameraMake, "DJI")
        XCTAssertEqual(resolved.cameraModel, "DJI Mini4 Pro")
    }

    func testDisabledEmbeddedFallbackModeSkipsEmbeddedFallbackWhenMetadataMissing() {
        let counter = ThreadSafeCounter()
        let extractor = AVFoundationVideoMetadataExtractor(
            embeddedFallbackMode: .disabled,
            embeddedMetadataExtractor: { _, _ in
                counter.increment()
                return VideoMetadataSnapshot(
                    captureDateTime: Date(timeIntervalSince1970: 1_700_123_456),
                    cameraMake: "Sony",
                    cameraModel: "ILCE-7CM2",
                    cameraSerial: nil
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

        XCTAssertEqual(counter.value, 0)
        XCTAssertNil(resolved.captureDateTime)
        XCTAssertNil(resolved.cameraMake)
        XCTAssertNil(resolved.cameraModel)
        XCTAssertNil(resolved.cameraSerial)
    }

    func testStructuredOnlyModeResolvesViaBoxWalkDecoder() throws {
        let tempDir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let minf = klvEntry(key: "MINF", type: "c", value: Data("HERO10 Black".utf8))
        let gpmf = box("GPMF", payload: minf)
        let udta = box("udta", payload: gpmf)
        let moov = box("moov", payload: udta)
        let fileURL = tempDir.appendingPathComponent("synthetic.mp4")
        try moov.write(to: fileURL)

        let extractor = AVFoundationVideoMetadataExtractor(embeddedFallbackMode: .structuredOnly)
        let primary = VideoMetadataSnapshot(captureDateTime: nil, cameraMake: nil, cameraModel: nil, cameraSerial: nil)
        let resolved = extractor.resolveEmbeddedFallbackIfNeeded(primary: primary, fileURL: fileURL)

        XCTAssertEqual(resolved.cameraMake, "GoPro")
        XCTAssertEqual(resolved.cameraModel, "HERO10 Black")
    }

    /// `.structuredOnly` (used by the fast preview scan) must never fall
    /// through to the blind head/tail text scan -- only `.full` (the real
    /// ingest scan) does. Same input file, only the mode differs.
    func testStructuredOnlyModeDoesNotFallBackToBlindTextScan() throws {
        let tempDir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let data = Data("junk\u{0}\u{0}DJI OsmoAction6\u{0}\u{0}more junk padding".utf8)
        let fileURL = tempDir.appendingPathComponent("synthetic.mp4")
        try data.write(to: fileURL)

        let primary = VideoMetadataSnapshot(captureDateTime: nil, cameraMake: nil, cameraModel: nil, cameraSerial: nil)

        let structuredOnlyResult = AVFoundationVideoMetadataExtractor(embeddedFallbackMode: .structuredOnly)
            .resolveEmbeddedFallbackIfNeeded(primary: primary, fileURL: fileURL)
        let fullResult = AVFoundationVideoMetadataExtractor(embeddedFallbackMode: .full)
            .resolveEmbeddedFallbackIfNeeded(primary: primary, fileURL: fileURL)

        XCTAssertNil(structuredOnlyResult.cameraModel)
        XCTAssertEqual(fullResult.cameraModel, "DJI OsmoAction6")
    }

    func testRequiresEmbeddedFallbackPolicy() {
        XCTAssertFalse(AVFoundationVideoMetadataExtractor.requiresEmbeddedFallback(
            VideoMetadataSnapshot(captureDateTime: nil, cameraMake: "Sony", cameraModel: nil, cameraSerial: nil)
        ))
        XCTAssertTrue(AVFoundationVideoMetadataExtractor.requiresEmbeddedFallback(
            VideoMetadataSnapshot(captureDateTime: Date(), cameraMake: nil, cameraModel: nil, cameraSerial: nil)
        ))
        XCTAssertTrue(AVFoundationVideoMetadataExtractor.requiresEmbeddedFallback(
            VideoMetadataSnapshot(captureDateTime: nil, cameraMake: nil, cameraModel: nil, cameraSerial: "ABC12345")
        ))
        XCTAssertFalse(AVFoundationVideoMetadataExtractor.requiresEmbeddedFallback(
            VideoMetadataSnapshot(captureDateTime: Date(), cameraMake: "Sony", cameraModel: nil, cameraSerial: nil)
        ))
    }

    func testRequiresSidecarFallbackPolicy() {
        XCTAssertFalse(AVFoundationVideoMetadataExtractor.requiresSidecarFallback(
            VideoMetadataSnapshot(captureDateTime: Date(), cameraMake: "Sony", cameraModel: "FX3", cameraSerial: "1234")
        ))
        XCTAssertTrue(AVFoundationVideoMetadataExtractor.requiresSidecarFallback(
            VideoMetadataSnapshot(captureDateTime: nil, cameraMake: "Sony", cameraModel: "FX3", cameraSerial: "1234")
        ))
        XCTAssertTrue(AVFoundationVideoMetadataExtractor.requiresSidecarFallback(
            VideoMetadataSnapshot(captureDateTime: Date(), cameraMake: nil, cameraModel: "FX3", cameraSerial: "1234")
        ))
    }

    // MARK: - Helpers

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func box(_ type: String, payload: Data = Data()) -> Data {
        var data = Data()
        let size = UInt32(8 + payload.count)
        data.append(contentsOf: withUnsafeBytes(of: size.bigEndian) { Array($0) })
        data.append(type.data(using: .ascii)!)
        data.append(payload)
        return data
    }

    /// GoPro GPMF KLV entry: FourCC key, 1-char type, element size == the
    /// value's byte count, count == 1, 4-byte-aligned padding.
    private func klvEntry(key: String, type: String, value: Data) -> Data {
        var data = Data(key.utf8)
        data.append(type.utf8.first!)
        data.append(UInt8(value.count))
        data.append(contentsOf: [0x00, 0x01])
        data.append(value)
        let padding = (4 - (value.count % 4)) % 4
        data.append(Data(repeating: 0, count: padding))
        return data
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
