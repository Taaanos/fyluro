import Foundation
import XCTest
@testable import RollKeepCore

/// Integration coverage for the M1 tier additions to
/// `VideoEmbeddedBoxMetadataResolver`: moov-level uuid (Canon), udta-level
/// uuid (Garmin), and the direct-tag tier's fill-only-blank-fields priority
/// relative to the structured tier. Uses the same synthesized-box style as
/// `VideoEmbeddedBoxMetadataResolverTests`.
final class VideoEmbeddedBoxMetadataResolverVendorTierTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("video-resolver-vendor-tier-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
    }

    func testResolvesMoovLevelUUIDEvenWithoutUdta() throws {
        let usertype = Data(repeating: 0xAA, count: 16)
        let uuidBox = box("uuid", payload: usertype + Data("content".utf8))
        let moov = box("moov", payload: uuidBox) // no udta child at all
        let fileURL = try writeFile(moov)

        let resolver = VideoEmbeddedBoxMetadataResolver(
            moovUUIDDecoders: [
                VideoUUIDVendorDecoder(usertype: usertype, label: "acme") { data in
                    (make: "Acme", model: String(decoding: data, as: UTF8.self), serial: nil)
                },
            ]
        )

        let snapshot = resolver.extract(from: fileURL, parser: VideoCreationDateParser(), textScanByteCount: 2048)

        XCTAssertEqual(snapshot.cameraMake, "Acme")
        XCTAssertEqual(snapshot.cameraModel, "content")
        XCTAssertEqual(snapshot.cameraModelSelectionRule, "embedded_box_metadata(moov_uuid_acme)")
    }

    func testResolvesUdtaLevelUUIDSiblingOfFourCCAtoms() throws {
        let usertype = Data(repeating: 0xBB, count: 16)
        let uuidBox = box("uuid", payload: usertype + Data("VIRB 360".utf8))
        let udta = box("udta", payload: uuidBox)
        let moov = box("moov", payload: udta)
        let fileURL = try writeFile(moov)

        let resolver = VideoEmbeddedBoxMetadataResolver(
            udtaUUIDDecoders: [
                VideoUUIDVendorDecoder(usertype: usertype, label: "garmin") { data in
                    (make: "Garmin", model: String(decoding: data, as: UTF8.self), serial: nil)
                },
            ]
        )

        let snapshot = resolver.extract(from: fileURL, parser: VideoCreationDateParser(), textScanByteCount: 2048)

        XCTAssertEqual(snapshot.cameraMake, "Garmin")
        XCTAssertEqual(snapshot.cameraModel, "VIRB 360")
        XCTAssertEqual(snapshot.cameraModelSelectionRule, "embedded_box_metadata(udta_uuid_garmin)")
    }

    func testUnmatchedUUIDUsertypeFallsThroughToTextScan() throws {
        let uuidBox = box("uuid", payload: Data(repeating: 0xCC, count: 16) + Data("ignored".utf8))
        let udta = box("udta", payload: uuidBox)
        let moov = box("moov", payload: udta)
        let fileURL = try writeFile(moov)

        let resolver = VideoEmbeddedBoxMetadataResolver(
            udtaUUIDDecoders: [
                VideoUUIDVendorDecoder(usertype: Data(repeating: 0xDD, count: 16), label: "other") { _ in
                    (make: "ShouldNotMatch", model: nil, serial: nil)
                },
            ],
            textScanExtractor: { _, _, _ in
                VideoMetadataSnapshot(captureDateTime: nil, cameraMake: "FromTextScan", cameraModel: nil, cameraSerial: nil)
            }
        )

        let snapshot = resolver.extract(from: fileURL, parser: VideoCreationDateParser(), textScanByteCount: 2048)

        XCTAssertEqual(snapshot.cameraMake, "FromTextScan")
    }

    /// Structured tier resolves make; direct-tag tier must only fill the
    /// still-empty model, never overwrite the structured make.
    func testDirectTagTierOnlyFillsFieldsStructuredTierLeftEmpty() throws {
        // Payload must be non-empty: ISOBMFFBoxWalker.readPayload returns nil
        // for a zero-length payload (nothing to decode), which would make
        // the structured decoder silently unreachable in this test.
        let structuredAtom = box("FAKE", payload: Data([0x01]))
        let directTagAtom = box("\u{A9}mak", payload: Data("WrongMake".utf8))
            + box("\u{A9}mod", payload: Data("RightModel".utf8))
        let udta = box("udta", payload: structuredAtom + directTagAtom)
        let moov = box("moov", payload: udta)
        let fileURL = try writeFile(moov)

        let resolver = VideoEmbeddedBoxMetadataResolver(
            vendorAtomDecoders: [
                "FAKE": { _ in (make: "StructuredMake", model: nil, serial: nil) },
            ],
            directTagDecoders: [
                "\u{A9}mak": { data in (make: String(decoding: data, as: UTF8.self), model: nil, serial: nil) },
                "\u{A9}mod": { data in (make: nil, model: String(decoding: data, as: UTF8.self), serial: nil) },
            ]
        )

        let snapshot = resolver.extract(from: fileURL, parser: VideoCreationDateParser(), textScanByteCount: 2048)

        XCTAssertEqual(snapshot.cameraMake, "StructuredMake")
        XCTAssertEqual(snapshot.cameraModel, "RightModel")
    }

    func testDirectTagTierAloneAccumulatesAcrossMultipleAtoms() throws {
        let atoms = box("\u{A9}mak", payload: Data("Acme".utf8))
            + box("slno", payload: Data("SN1".utf8))
        let udta = box("udta", payload: atoms)
        let moov = box("moov", payload: udta)
        let fileURL = try writeFile(moov)

        let resolver = VideoEmbeddedBoxMetadataResolver(
            directTagDecoders: [
                "\u{A9}mak": { data in (make: String(decoding: data, as: UTF8.self), model: nil, serial: nil) },
                "slno": { data in (make: nil, model: nil, serial: String(decoding: data, as: UTF8.self)) },
            ]
        )

        let snapshot = resolver.extract(from: fileURL, parser: VideoCreationDateParser(), textScanByteCount: 2048)

        XCTAssertEqual(snapshot.cameraMake, "Acme")
        XCTAssertEqual(snapshot.cameraSerial, "SN1")
    }

    // MARK: - Helpers

    private func box(_ type: String, payload: Data = Data()) -> Data {
        var data = Data()
        data.append(contentsOf: withUnsafeBytes(of: UInt32(8 + payload.count).bigEndian) { Array($0) })
        // FourCC bytes are one raw byte per character (0xA9 for '©', not its
        // 2-byte UTF-8 encoding) -- the inverse of ISOBMFFBoxWalker.fourCC,
        // needed for tags like "\u{A9}mak". Plain .ascii encoding would
        // return nil (and crash the force-unwrap) for any such type string.
        data.append(Data(type.unicodeScalars.map { UInt8($0.value & 0xFF) }))
        data.append(payload)
        return data
    }

    private func writeFile(_ data: Data, name: String = UUID().uuidString) throws -> URL {
        let url = tempDirectory.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }
}
