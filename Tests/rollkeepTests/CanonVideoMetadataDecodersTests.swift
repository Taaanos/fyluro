import Foundation
import XCTest
@testable import RollKeepCore

final class CanonVideoMetadataDecodersTests: XCTestCase {
    // MARK: - CanonMovieUuidDecoder (CR3 / MP4 moov uuid content)

    func testMovieUuidDecoderReadsMakeModelFromCMT1AndSerialFromCMT2() {
        // ifd0 tail (2 entries): 8-byte header + 2-byte count + 2*12-byte
        // entries + 4-byte next-IFD = 38.
        let makeBytes = Array("Canon\0".utf8)
        let modelBytes = Array("EOS M50\0".utf8)
        let ifd0 = tiff(entries: [
            tiffEntry(tag: 0x010F, type: 2, count: UInt32(makeBytes.count), value: u32(38, .bigEndian)),
            tiffEntry(
                tag: 0x0110, type: 2, count: UInt32(modelBytes.count),
                value: u32(38 + UInt32(makeBytes.count), .bigEndian)
            ),
        ], order: .bigEndian, tail: makeBytes + modelBytes)
        // exifIFD tail (1 entry): 8 + 2 + 12 + 4 = 26.
        let serialBytes = Array("SN0001\0".utf8)
        let exifIFD = tiff(entries: [
            tiffEntry(tag: 0xA431, type: 2, count: UInt32(serialBytes.count), value: u32(26, .bigEndian)),
        ], order: .bigEndian, tail: serialBytes)

        let content = box("CMT1", payload: Data(ifd0)) + box("CMT2", payload: Data(exifIFD))

        let decoded = CanonMovieUuidDecoder().decode(content)

        XCTAssertEqual(decoded.make, "Canon")
        XCTAssertEqual(decoded.model, "EOS M50")
        XCTAssertEqual(decoded.serial, "SN0001")
    }

    func testMovieUuidDecoderFallsBackToCNTHWhenCMT1MissingModel() {
        let cnda = jpegWithExifModel("PowerShot S95")
        let cnth = box("CNDA", payload: Data(cnda))

        let decoded = CanonMovieUuidDecoder().decode(box("CNTH", payload: cnth))

        XCTAssertEqual(decoded.model, "PowerShot S95")
    }

    func testMovieUuidDecoderReturnsNilFieldsForUnrecognizedContent() {
        let decoded = CanonMovieUuidDecoder().decode(Data(repeating: 0xAB, count: 16))

        XCTAssertNil(decoded.make)
        XCTAssertNil(decoded.model)
        XCTAssertNil(decoded.serial)
    }

    // MARK: - CanonCNTHMetadataDecoder (standalone udta CNTH, e.g. PowerShot S95)

    func testCNTHDecoderReadsExifFromEmbeddedThmJPEG() {
        let jpeg = jpegWithExifModel("PowerShot S95")

        let decoded = CanonCNTHMetadataDecoder().decode(box("CNDA", payload: Data(jpeg)))

        XCTAssertEqual(decoded.model, "PowerShot S95")
    }

    func testCNTHDecoderReturnsNilWhenNoCNDAChild() {
        let decoded = CanonCNTHMetadataDecoder().decode(box("CNOP", payload: Data([1, 2, 3])))

        XCTAssertNil(decoded.model)
    }

    // MARK: - Helpers (mirrors ExifIFDFieldReaderTests' byte builders)

    private func u32(_ value: UInt32, _ order: ExifByteOrder) -> [UInt8] {
        let bytes = [UInt8(value >> 24), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
        return order == .bigEndian ? bytes : bytes.reversed()
    }

    private func u16(_ value: UInt16, _ order: ExifByteOrder) -> [UInt8] {
        order == .bigEndian ? [UInt8(value >> 8), UInt8(value & 0xFF)] : [UInt8(value & 0xFF), UInt8(value >> 8)]
    }

    private struct Entry {
        let tag: UInt16
        let type: UInt16
        let count: UInt32
        let value: [UInt8]
    }

    private func tiffEntry(tag: UInt16, type: UInt16, count: UInt32, value: [UInt8]) -> Entry {
        Entry(tag: tag, type: type, count: count, value: value)
    }

    private func tiff(entries: [Entry], order: ExifByteOrder, tail: [UInt8]) -> [UInt8] {
        var bytes: [UInt8] = order == .bigEndian ? [0x4D, 0x4D] : [0x49, 0x49]
        bytes += u16(0x2A, order) + u32(8, order)
        bytes += u16(UInt16(entries.count), order)
        for entry in entries {
            bytes += u16(entry.tag, order) + u16(entry.type, order) + u32(entry.count, order) + entry.value
        }
        bytes += u32(0, order)
        bytes += tail
        return bytes
    }

    private func jpegWithExifModel(_ model: String) -> [UInt8] {
        let modelBytes = Array(model.utf8) + [0x00]
        var tiffBytes = [0x49, 0x49] + u16(0x2A, .littleEndian) + u32(8, .littleEndian)
        tiffBytes += u16(1, .littleEndian)
        tiffBytes += u16(0x0110, .littleEndian) + u16(2, .littleEndian) + u32(UInt32(modelBytes.count), .littleEndian)
        tiffBytes += u32(26, .littleEndian)
        tiffBytes += u32(0, .littleEndian)
        tiffBytes += modelBytes

        let exifPayload = Array("Exif\0\0".utf8) + tiffBytes
        let app1 = [0xFF, 0xE1] + u16(UInt16(exifPayload.count + 2), .bigEndian) + exifPayload
        return [0xFF, 0xD8] + app1 + [0xFF, 0xD9]
    }

    private func box(_ type: String, payload: Data) -> Data {
        var data = Data()
        data.append(contentsOf: withUnsafeBytes(of: UInt32(8 + payload.count).bigEndian) { Array($0) })
        data.append(type.data(using: .ascii)!)
        data.append(payload)
        return data
    }
}
