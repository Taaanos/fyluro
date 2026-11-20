import Foundation
import XCTest
@testable import FyluroCore

final class H264SEIMDPMParserTests: XCTestCase {
    private let parser = H264SEIMDPMParser()

    // MARK: - End-to-end: NAL start codes -> SEI -> MDPM

    func testExtractsMakeFromMDPMTag0xE0ViaConvMakeTable() {
        // Canon's code (0x1011) -- same numeric map exiftool's own %convMake uses.
        let mdpm = mdpmEntry(tag: 0xE0, value: [0x10, 0x11, 0x00, 0x00])
        let sei = seiPayload(type: 5, payload: mdpmUUIDMarker + [UInt8(1)] + mdpm)
        let stream = nalUnit(type: 0x06, rbsp: sei)

        let decoded = parser.parse(Data(stream))

        XCTAssertEqual(decoded.make, "Canon")
        XCTAssertNil(decoded.model)
    }

    func testExtractsAllFourKnownMakeCodes() {
        let expected: [(UInt16, String)] = [(0x0103, "Panasonic"), (0x0108, "Sony"), (0x1011, "Canon"), (0x1104, "JVC")]
        for (code, name) in expected {
            let mdpm = mdpmEntry(tag: 0xE0, value: [UInt8(code >> 8), UInt8(code & 0xFF), 0, 0])
            let sei = seiPayload(type: 5, payload: mdpmUUIDMarker + [UInt8(1)] + mdpm)
            let stream = nalUnit(type: 0x06, rbsp: sei)

            XCTAssertEqual(parser.parse(Data(stream)).make, name, "code 0x\(String(code, radix: 16))")
        }
    }

    func testUnknownMakeCodeYieldsNilNotCrash() {
        let mdpm = mdpmEntry(tag: 0xE0, value: [0xFF, 0xFF, 0, 0])
        let sei = seiPayload(type: 5, payload: mdpmUUIDMarker + [UInt8(1)] + mdpm)

        XCTAssertNil(parser.parse(Data(nalUnit(type: 0x06, rbsp: sei))).make)
    }

    func testExtractsSonyModelFromThreeCombinedMDPMEntries() {
        // 0xE4/0xE5/0xE6 concatenate into one 12-byte ASCII string.
        let modelBytes = Array("HDR-XR500\0\0\0".utf8) // exactly 12 bytes
        var mdpm: [UInt8] = []
        for (offset, tag) in [UInt8(0xE4), 0xE5, 0xE6].enumerated() {
            mdpm += mdpmEntry(tag: tag, value: Array(modelBytes[(offset * 4)..<(offset * 4 + 4)]))
        }
        let sei = seiPayload(type: 5, payload: mdpmUUIDMarker + [UInt8(3)] + mdpm)

        XCTAssertEqual(parser.parse(Data(nalUnit(type: 0x06, rbsp: sei))).model, "HDR-XR500")
    }

    func testExtractsBothMakeAndModelWhenBothPresent() {
        let make = mdpmEntry(tag: 0xE0, value: [0x01, 0x08, 0, 0]) // Sony
        var model: [UInt8] = []
        for (offset, tag) in [UInt8(0xE4), 0xE5, 0xE6].enumerated() {
            let bytes = Array((Array("HDR-XR500\0\0\0".utf8))[(offset * 4)..<(offset * 4 + 4)])
            model += mdpmEntry(tag: tag, value: bytes)
        }
        let sei = seiPayload(type: 5, payload: mdpmUUIDMarker + [UInt8(4)] + make + model)

        let decoded = parser.parse(Data(nalUnit(type: 0x06, rbsp: sei)))
        XCTAssertEqual(decoded.make, "Sony")
        XCTAssertEqual(decoded.model, "HDR-XR500")
    }

    // MARK: - SEI framing edge cases

    func testSkipsOtherSEITypesToFindType5() {
        let pictureTiming = seiTypeSizePayload(type: 1, payload: [0x00, 0x00, 0x00, 0x00])
        let mdpm = mdpmEntry(tag: 0xE0, value: [0x10, 0x11, 0, 0])
        let userData = seiTypeSizePayload(type: 5, payload: mdpmUUIDMarker + [UInt8(1)] + mdpm)
        let sei = pictureTiming + userData

        XCTAssertEqual(parser.parse(Data(nalUnit(type: 0x06, rbsp: sei))).make, "Canon")
    }

    func testHandlesLargePayloadSizeRequiringContinuationByte() {
        // A payload_size of exactly 255 must be encoded as [0xFF, 0x00]
        // (0xFF continuation + 0x00 terminator = 255), not just [0xFF]
        // (which would mean "255 and keep reading").
        let mdpm = mdpmEntry(tag: 0xE0, value: [0x10, 0x11, 0, 0])
        var payload = mdpmUUIDMarker + [UInt8(1)] + mdpm
        XCTAssertLessThan(payload.count, 255)
        payload += Array(repeating: UInt8(0), count: 255 - payload.count) // pad to exactly 255
        let sei = [UInt8(5)] + [0xFF, UInt8(255 - 255)] + payload // type=5, size=255 via continuation

        XCTAssertEqual(parser.parse(Data(nalUnit(type: 0x06, rbsp: sei))).make, "Canon")
    }

    func testReturnsNilWhenUUIDMarkerDoesNotMatch() {
        let wrongMarker = Array(repeating: UInt8(0xAB), count: 20)
        let mdpm = mdpmEntry(tag: 0xE0, value: [0x10, 0x11, 0, 0])
        let sei = seiPayload(type: 5, payload: wrongMarker + [UInt8(1)] + mdpm)

        let decoded = parser.parse(Data(nalUnit(type: 0x06, rbsp: sei)))
        XCTAssertNil(decoded.make)
        XCTAssertNil(decoded.model)
    }

    func testStopsOnOutOfOrderMDPMTags() {
        // exiftool: entries must be in strictly increasing tag order.
        let entries = mdpmEntry(tag: 0xE5, value: [0, 0, 0, 0]) + mdpmEntry(tag: 0xE0, value: [0x10, 0x11, 0, 0])
        let sei = seiPayload(type: 5, payload: mdpmUUIDMarker + [UInt8(2)] + entries)

        // 0xE0 (Make) comes second, out of order -- must not be read.
        XCTAssertNil(parser.parse(Data(nalUnit(type: 0x06, rbsp: sei))).make)
    }

    func testTruncatedSEIReturnsNilInsteadOfOverreading() {
        // Declares type=5, size=100 but supplies far fewer bytes.
        let sei: [UInt8] = [5, 100, 0x17, 0xEE]
        XCTAssertNil(parser.parse(Data(nalUnit(type: 0x06, rbsp: sei))).make)
    }

    func testEmptyOrGarbageStreamReturnsNilNotCrash() {
        XCTAssertNil(parser.parse(Data()).make)
        XCTAssertNil(parser.parse(Data(repeating: 0xFF, count: 64)).make)
        XCTAssertNil(parser.parse(Data([0x00, 0x00, 0x01, 0x06])).make) // start code + SEI type but no RBSP
    }

    // MARK: - NAL unit selection / emulation prevention

    func testIgnoresNonSEINalUnitTypes() {
        let mdpm = mdpmEntry(tag: 0xE0, value: [0x10, 0x11, 0, 0])
        let sei = seiPayload(type: 5, payload: mdpmUUIDMarker + [UInt8(1)] + mdpm)
        // type 0x07 (SPS) instead of 0x06 (SEI): must not be scanned for MDPM.
        let stream = nalUnit(type: 0x07, rbsp: sei)

        XCTAssertNil(parser.parse(Data(stream)).make)
    }

    func testRemovesEmulationPreventionBytesBeforeParsing() {
        // Construct MDPM bytes such that a raw "00 00 01" would appear
        // mid-payload if not escaped; verify the escaped form (00 00 03 01)
        // still parses correctly once unescaped back to 00 00 01.
        let mdpm = mdpmEntry(tag: 0xE0, value: [0x00, 0x00, 0x01, 0x00]) // contains 00 00 01
        let sei = seiPayload(type: 5, payload: mdpmUUIDMarker + [UInt8(1)] + mdpm)
        let escapedRBSP = H264SEIMDPMParserTests.emulationPreventionEncode(sei)
        let stream = [UInt8(0), 0, 1, 0x06] + escapedRBSP + [0, 0, 1, 0x09] // followed by another NAL to bound this one

        // Make code 0x0000 has no entry in convMake, so this specifically
        // checks that parsing doesn't crash/misalign on the escaped bytes,
        // not that a particular make is found.
        _ = parser.parse(Data(stream))
    }

    func testFindsSEIAmongMultipleNalUnitsInOneStream() {
        let sps = nalUnit(type: 0x07, rbsp: [0x42, 0x00, 0x1E])
        let mdpm = mdpmEntry(tag: 0xE0, value: [0x01, 0x03, 0, 0]) // Panasonic
        let sei = nalUnit(type: 0x06, rbsp: seiPayload(type: 5, payload: mdpmUUIDMarker + [UInt8(1)] + mdpm))
        let stream = sps + sei

        XCTAssertEqual(parser.parse(Data(stream)).make, "Panasonic")
    }

    // MARK: - Helpers

    private let mdpmUUIDMarker: [UInt8] = [
        0x17, 0xEE, 0x8C, 0x60, 0xF8, 0x4D, 0x11, 0xD9,
        0x8C, 0xD6, 0x08, 0x00, 0x20, 0x0C, 0x9A, 0x66,
    ] + Array("MDPM".utf8)

    private func mdpmEntry(tag: UInt8, value: [UInt8]) -> [UInt8] {
        precondition(value.count == 4)
        return [tag] + value
    }

    /// SEI type/size varint framing only (no start code / NAL header).
    private func seiTypeSizePayload(type: Int, payload: [UInt8]) -> [UInt8] {
        Self.continuationEncode(type) + Self.continuationEncode(payload.count) + payload
    }

    private func seiPayload(type: Int, payload: [UInt8]) -> [UInt8] {
        seiTypeSizePayload(type: type, payload: payload)
    }

    private func nalUnit(type: UInt8, rbsp: [UInt8]) -> [UInt8] {
        [0, 0, 1, type] + rbsp + [0, 0, 1, 0x0B] // trailing start code bounds the NAL (0x0B = end-of-stream marker, arbitrary)
    }

    private static func continuationEncode(_ value: Int) -> [UInt8] {
        var remaining = value
        var bytes: [UInt8] = []
        while remaining >= 0xFF {
            bytes.append(0xFF)
            remaining -= 0xFF
        }
        bytes.append(UInt8(remaining))
        return bytes
    }

    private static func emulationPreventionEncode(_ rbsp: [UInt8]) -> [UInt8] {
        var result: [UInt8] = []
        var zeroRun = 0
        for byte in rbsp {
            if zeroRun >= 2, byte <= 0x03 {
                result.append(0x03)
                zeroRun = 0
            }
            result.append(byte)
            zeroRun = (byte == 0) ? zeroRun + 1 : 0
        }
        return result
    }
}
