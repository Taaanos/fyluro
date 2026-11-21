import Foundation
import XCTest
@testable import FyluroCore

final class NikonNCDTMetadataDecoderTests: XCTestCase {
    private let decoder = NikonNCDTMetadataDecoder()

    func testDecodesMakeModelSerialFromNCTGChild() {
        var nctg = Data()
        nctg += nctgRecord(tag: 0x01, format: 2, value: Data("NIKON CORPORATION\0".utf8))
        nctg += nctgRecord(tag: 0x02, format: 2, value: Data("NIKON Z9\0".utf8))
        nctg += nctgRecord(tag: 0x110_A431, format: 2, value: Data("SN00112233\0".utf8))
        let ncdt = box("NCTG", payload: nctg) + box("NCHD", payload: Data([0x30, 0x31, 0x30, 0x30]))

        let decoded = decoder.decode(ncdt)

        XCTAssertEqual(decoded.make, "NIKON CORPORATION")
        XCTAssertEqual(decoded.model, "NIKON Z9")
        XCTAssertEqual(decoded.serial, "SN00112233")
    }

    func testIgnoresNonASCIIFormatRecordsForIdentityTags() {
        // Same tag ID as Make, but format 4 (int32u): must not be read as a string.
        let nctg = nctgRecord(tag: 0x01, format: 4, value: Data([0x00, 0x00, 0x00, 0x2A]))
        let ncdt = box("NCTG", payload: nctg)

        XCTAssertNil(decoder.decode(ncdt).make)
    }

    func testReturnsNilFieldsWhenNCTGChildAbsent() {
        let ncdt = box("NCHD", payload: Data([0x30, 0x31]))

        let decoded = decoder.decode(ncdt)

        XCTAssertNil(decoded.make)
        XCTAssertNil(decoded.model)
        XCTAssertNil(decoded.serial)
    }

    func testStopsOnTruncatedRecordInsteadOfOverreading() {
        // Header claims count=100 of a 1-byte format, but only 3 bytes follow.
        var nctg = Data()
        nctg.append(contentsOf: [0x00, 0x00, 0x00, 0x01]) // tag 0x01 (Make)
        nctg.append(contentsOf: [0x00, 0x02]) // format 2 (ASCII)
        nctg.append(contentsOf: [0x00, 0x64]) // count 100
        nctg.append(Data([0x41, 0x42, 0x43])) // only 3 bytes present
        let ncdt = box("NCTG", payload: nctg)

        XCTAssertNil(decoder.decode(ncdt).make)
    }

    func testStopsOnUnknownFormatCode() {
        var nctg = Data()
        nctg.append(contentsOf: [0x00, 0x00, 0x00, 0x01])
        nctg.append(contentsOf: [0x00, 0xFF]) // format 0xFF: not a valid EXIF format code
        nctg.append(contentsOf: [0x00, 0x01])
        let ncdt = box("NCTG", payload: nctg)

        XCTAssertNil(decoder.decode(ncdt).make)
    }

    private func nctgRecord(tag: UInt32, format: UInt16, value: Data) -> Data {
        var data = Data()
        data.append(contentsOf: withUnsafeBytes(of: tag.bigEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: format.bigEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: UInt16(value.count).bigEndian) { Array($0) })
        data.append(value)
        return data
    }

    private func box(_ type: String, payload: Data) -> Data {
        var data = Data()
        data.append(contentsOf: withUnsafeBytes(of: UInt32(8 + payload.count).bigEndian) { Array($0) })
        data.append(type.data(using: .ascii)!)
        data.append(payload)
        return data
    }
}
