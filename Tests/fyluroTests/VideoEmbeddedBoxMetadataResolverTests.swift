import Foundation
import XCTest
@testable import FyluroCore

final class VideoEmbeddedBoxMetadataResolverTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("video-embedded-box-resolver-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
    }

    func testDispatchesToRegisteredDecoderForUdtaChild() throws {
        let vendorAtom = box("FAKE", payload: Data("Acme Model X".utf8))
        let udta = box("udta", payload: vendorAtom)
        let moov = box("moov", payload: udta)
        let fileURL = try writeFile(moov)

        let resolver = VideoEmbeddedBoxMetadataResolver(
            vendorAtomDecoders: [
                "FAKE": { data in (make: "Acme", model: String(decoding: data, as: UTF8.self), serial: nil) },
            ],
            textScanExtractor: { _, _, _ in
                XCTFail("text scan should not run when a vendor decoder resolves the file")
                return .init(captureDateTime: nil, cameraMake: nil, cameraModel: nil, cameraSerial: nil)
            }
        )

        let snapshot = resolver.extract(from: fileURL, parser: VideoCreationDateParser(), textScanByteCount: 2048)

        XCTAssertEqual(snapshot.cameraMake, "Acme")
        XCTAssertEqual(snapshot.cameraModel, "Acme Model X")
        XCTAssertEqual(snapshot.cameraMakeSource, .embeddedMetadataMake)
        XCTAssertEqual(snapshot.cameraModelSource, .embeddedMetadataModel)
        XCTAssertEqual(snapshot.cameraModelSelectionRule, "embedded_box_metadata(fake)")
    }

    /// Reproduces the real DJI case: the vendor atom's own model_name is a
    /// bare internal SKU ("AC006"), but a friendlier retail name ("DJI
    /// OsmoAction6") sits elsewhere in udta's bytes. The opaque code alone
    /// must not win over a friendlier alternative found in the same atom.
    func testPrefersFriendlierModelFromUdtaBytesWhenDecoderModelIsOpaqueCode() throws {
        let vendorAtom = box("Xtra", payload: Data("AC006".utf8))
        let friendlierNameElsewhereInUdta = Data("\u{0}\u{0}DJI OsmoAction6\u{0}\u{0}".utf8)
        let udta = box("udta", payload: vendorAtom + friendlierNameElsewhereInUdta)
        let moov = box("moov", payload: udta)
        let fileURL = try writeFile(moov)

        let resolver = VideoEmbeddedBoxMetadataResolver(
            vendorAtomDecoders: [
                "Xtra": { data in (make: "DJI", model: String(decoding: data, as: UTF8.self), serial: nil) },
            ]
        )

        let snapshot = resolver.extract(from: fileURL, parser: VideoCreationDateParser(), textScanByteCount: 2048)

        XCTAssertEqual(snapshot.cameraMake, "DJI")
        XCTAssertEqual(snapshot.cameraModel, "DJI OsmoAction6")
        XCTAssertEqual(snapshot.cameraModelSelectionRule, "embedded_udta_printable_string_match")
    }

    func testKeepsOpaqueModelWhenNoFriendlierAlternativeFoundInUdta() throws {
        let vendorAtom = box("Xtra", payload: Data("AC006".utf8))
        let udta = box("udta", payload: vendorAtom)
        let moov = box("moov", payload: udta)
        let fileURL = try writeFile(moov)

        let resolver = VideoEmbeddedBoxMetadataResolver(
            vendorAtomDecoders: [
                "Xtra": { data in (make: "DJI", model: String(decoding: data, as: UTF8.self), serial: nil) },
            ]
        )

        let snapshot = resolver.extract(from: fileURL, parser: VideoCreationDateParser(), textScanByteCount: 2048)

        XCTAssertEqual(snapshot.cameraModel, "AC006")
        XCTAssertEqual(snapshot.cameraModelSelectionRule, "embedded_box_metadata(xtra)")
    }

    func testLocatesMetaXmlBoxAndReusesExistingXmlParsing() throws {
        let xmlText = """
        <NonRealTimeMeta><CreationDate value="2024-06-21T22:05:01+01:00"/><Device manufacturer="Sony" modelName="ILCE-7CM2" serialNo="4294967295"/></NonRealTimeMeta>
        """
        // meta and xml are both FullBoxes: 4-byte version+flags before content.
        let xmlBox = box("xml ", payload: fullBoxPayload(Data(xmlText.utf8)))
        let metaBox = box("meta", payload: fullBoxPayload(xmlBox))
        let fileURL = try writeFile(metaBox)

        let resolver = VideoEmbeddedBoxMetadataResolver(
            textScanExtractor: { _, _, _ in
                XCTFail("text scan should not run when meta/xml already resolved make+model")
                return .init(captureDateTime: nil, cameraMake: nil, cameraModel: nil, cameraSerial: nil)
            }
        )

        let snapshot = resolver.extract(from: fileURL, parser: VideoCreationDateParser(), textScanByteCount: 2048)

        XCTAssertEqual(snapshot.cameraMake, "Sony")
        XCTAssertEqual(snapshot.cameraModel, "ILCE-7CM2")
        XCTAssertNotNil(snapshot.captureDateTime)
    }

    func testFallsThroughToTextScanWhenNoKnownVendorAtomPresent() throws {
        let fileURL = try writeFile(box("free"))
        let textScanCalled = CallFlag()

        let resolver = VideoEmbeddedBoxMetadataResolver(
            textScanExtractor: { _, _, _ in
                textScanCalled.mark()
                return VideoMetadataSnapshot(
                    captureDateTime: nil,
                    cameraMake: "TextScanMake",
                    cameraModel: "TextScanModel",
                    cameraSerial: nil,
                    cameraMakeSelectionRule: "embedded_text_direct",
                    cameraModelSelectionRule: "embedded_text_direct"
                )
            }
        )

        let snapshot = resolver.extract(from: fileURL, parser: VideoCreationDateParser(), textScanByteCount: 2048)

        XCTAssertTrue(textScanCalled.wasCalled)
        XCTAssertEqual(snapshot.cameraMake, "TextScanMake")
        XCTAssertEqual(snapshot.cameraModel, "TextScanModel")
    }

    /// A decoder that resolves only `serial` (no make/model) still leaves
    /// `requiresTextScanFallback` true, so the text scan runs and fills in
    /// make/model -- but must not clobber the serial the box walk already
    /// found. This is the realistic shape of the "box-walk wins" merge rule,
    /// since a decoder that resolves make/model always short-circuits the
    /// text scan entirely (see testDispatchesToRegisteredDecoderForUdtaChild).
    func testMergePreservesBoxWalkSerialWhileFillingMakeModelFromTextScan() throws {
        let vendorAtom = box("FAKE", payload: Data("ignored".utf8))
        let udta = box("udta", payload: vendorAtom)
        let moov = box("moov", payload: udta)
        let fileURL = try writeFile(moov)

        let resolver = VideoEmbeddedBoxMetadataResolver(
            vendorAtomDecoders: [
                "FAKE": { _ in (make: nil, model: nil, serial: "REAL-SERIAL") },
            ],
            textScanExtractor: { _, _, _ in
                VideoMetadataSnapshot(
                    captureDateTime: nil,
                    cameraMake: "TextScanMake",
                    cameraModel: "TextScanModel",
                    cameraSerial: "WRONG-SERIAL",
                    cameraMakeSelectionRule: "embedded_text_direct",
                    cameraModelSelectionRule: "embedded_text_direct",
                    cameraSerialSelectionRule: "embedded_text_direct"
                )
            }
        )

        let snapshot = resolver.extract(from: fileURL, parser: VideoCreationDateParser(), textScanByteCount: 2048)

        XCTAssertEqual(snapshot.cameraMake, "TextScanMake")
        XCTAssertEqual(snapshot.cameraModel, "TextScanModel")
        XCTAssertEqual(snapshot.cameraSerial, "REAL-SERIAL")
    }

    func testUnknownUdtaChildFourCCFallsThroughCleanly() throws {
        let unknownAtom = box("AMBA", payload: Data(repeating: 0x00, count: 12))
        let udta = box("udta", payload: unknownAtom)
        let moov = box("moov", payload: udta)
        let fileURL = try writeFile(moov)
        let textScanCalled = CallFlag()

        let resolver = VideoEmbeddedBoxMetadataResolver(
            vendorAtomDecoders: [
                "FAKE": { data in (make: "Acme", model: String(decoding: data, as: UTF8.self), serial: nil) },
            ],
            textScanExtractor: { _, _, _ in
                textScanCalled.mark()
                return .init(captureDateTime: nil, cameraMake: nil, cameraModel: nil, cameraSerial: nil)
            }
        )

        let snapshot = resolver.extract(from: fileURL, parser: VideoCreationDateParser(), textScanByteCount: 2048)

        XCTAssertTrue(textScanCalled.wasCalled)
        XCTAssertNil(snapshot.cameraMake)
        XCTAssertNil(snapshot.cameraModel)
    }

    private final class CallFlag: @unchecked Sendable {
        private(set) var wasCalled = false
        func mark() { wasCalled = true }
    }

    private func box(_ type: String, payload: Data = Data()) -> Data {
        var data = Data()
        let size = UInt32(8 + payload.count)
        data.append(contentsOf: withUnsafeBytes(of: size.bigEndian) { Array($0) })
        data.append(type.data(using: .ascii)!)
        data.append(payload)
        return data
    }

    private func fullBoxPayload(_ content: Data) -> Data {
        Data([0, 0, 0, 0]) + content
    }

    private func writeFile(_ data: Data, name: String = UUID().uuidString) throws -> URL {
        let url = tempDirectory.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }
}
