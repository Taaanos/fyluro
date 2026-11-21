import Foundation
import XCTest
@testable import FyluroCore

final class ExifIFDFieldReaderTests: XCTestCase {
    private let reader = ExifIFDFieldReader()

    func testReadsMakeModelLittleEndianWithOffsetAndInlineValues() {
        // Tail (out-of-line values) starts at 8 header + 2 count + 2*12 entries + 4 next-IFD = 38.
        let entries = [
            Entry(tag: 0x010F, type: 2, count: 9, value: u32(38, .littleEndian)),
            Entry(tag: 0x0110, type: 2, count: 4, value: [0x58, 0x2D, 0x54, 0x00]), // "X-T\0"
        ]
        let data = Data(
            tiffHeader(.littleEndian)
                + ifdBytes(entries, .littleEndian)
                + Array("FUJIFILM\0".utf8)
        )

        let fields = reader.readTIFF(data)

        XCTAssertEqual(fields?.make, "FUJIFILM")
        XCTAssertEqual(fields?.model, "X-T")
        XCTAssertNil(fields?.serial)
    }

    func testReadsBigEndian() {
        let entries = [
            Entry(tag: 0x0110, type: 2, count: 11, value: u32(26, .bigEndian)),
        ]
        let data = Data(
            tiffHeader(.bigEndian)
                + ifdBytes(entries, .bigEndian)
                + Array("NIKON D850\0".utf8)
        )

        let fields = reader.readTIFF(data)

        XCTAssertEqual(fields?.model, "NIKON D850")
        XCTAssertNil(fields?.make)
    }

    func testPrefersBodySerialNumberFromExifIFDOverDNGSerial() {
        // IFD0 at 8 (2 entries -> 30 bytes), ExifIFD at 38 (1 entry -> 18 bytes), string at 56.
        let ifd0 = [
            Entry(tag: 0x8769, type: 4, count: 1, value: u32(38, .littleEndian)),
            Entry(tag: 0xC62F, type: 2, count: 4, value: [0x39, 0x39, 0x39, 0x00]), // "999\0"
        ]
        let exifIFD = [
            Entry(tag: 0xA431, type: 2, count: 10, value: u32(56, .littleEndian)),
        ]
        let data = Data(
            tiffHeader(.littleEndian)
                + ifdBytes(ifd0, .littleEndian)
                + ifdBytes(exifIFD, .littleEndian)
                + Array("SN1234567\0".utf8)
        )

        XCTAssertEqual(reader.readTIFF(data)?.serial, "SN1234567")
    }

    func testFallsBackToDNGSerialAndUniqueCameraModel() {
        let entries = [
            Entry(tag: 0xC614, type: 2, count: 10, value: u32(38, .littleEndian)),
            Entry(tag: 0xC62F, type: 2, count: 4, value: [0x35, 0x36, 0x37, 0x00]), // "567\0"
        ]
        let data = Data(
            tiffHeader(.littleEndian)
                + ifdBytes(entries, .littleEndian)
                + Array("LEICA M11\0".utf8)
        )

        let fields = reader.readTIFF(data)

        XCTAssertEqual(fields?.uniqueCameraModel, "LEICA M11")
        XCTAssertEqual(fields?.serial, "567")
        XCTAssertNil(fields?.make)
    }

    func testAcceptsRAWMagicVariants() {
        // RW2 (0x0055) and ORF ("RO"/"SR") keep the standard IFD layout
        // behind a nonstandard magic word; big-endian 0x4F52 is "MMOR".
        let model = Entry(tag: 0x0110, type: 2, count: 4, value: [0x47, 0x48, 0x37, 0x00]) // "GH7\0"

        for magic in [UInt16(0x0055), 0x4F52, 0x5352] {
            let data = Data(
                tiffHeader(.littleEndian, magic: magic)
                    + ifdBytes([model], .littleEndian)
            )
            XCTAssertEqual(reader.readTIFF(data)?.model, "GH7", "magic \(magic)")
        }

        let bigEndian = Data(
            tiffHeader(.bigEndian, magic: 0x4F52)
                + ifdBytes([model], .bigEndian)
        )
        XCTAssertEqual(reader.readTIFF(bigEndian)?.model, "GH7")
    }

    func testRejectsUnknownMagicOrderAndTruncatedHeader() {
        let entries = [Entry(tag: 0x0110, type: 2, count: 4, value: [0x41, 0x00, 0x00, 0x00])]

        let badMagic = Data(tiffHeader(.littleEndian, magic: 0x1234) + ifdBytes(entries, .littleEndian))
        XCTAssertNil(reader.readTIFF(badMagic))

        XCTAssertNil(reader.readTIFF(Data("XXXXXXXX".utf8)))
        XCTAssertNil(reader.readTIFF(Data([0x49, 0x49, 0x2A])))
        XCTAssertNil(reader.readTIFF(Data()))
    }

    func testSurvivesOutOfRangeIFDOffset() {
        let data = Data(tiffHeader(.littleEndian, ifd0Offset: 0xFFFF_FF00))

        let fields = reader.readTIFF(data)

        XCTAssertNotNil(fields)
        XCTAssertEqual(fields?.hasIdentity, false)
    }

    func testSurvivesHostileCountsAndOffsets() {
        // Entry count claims 0xFFFF entries but the data ends immediately.
        let hugeCount = Data(tiffHeader(.littleEndian) + u16(0xFFFF, .littleEndian))
        XCTAssertEqual(reader.readTIFF(hugeCount)?.hasIdentity, false)

        // ASCII value claims 0xFFFFFFFF bytes -- must be clamped, not read.
        let hugeValue = [Entry(tag: 0x010F, type: 2, count: 0xFFFF_FFFF, value: u32(8, .littleEndian))]
        let hugeValueData = Data(tiffHeader(.littleEndian) + ifdBytes(hugeValue, .littleEndian))
        XCTAssertEqual(reader.readTIFF(hugeValueData)?.hasIdentity, false)

        // Value offset far outside the data.
        let farOffset = [Entry(tag: 0x010F, type: 2, count: 20, value: u32(0xFFFF_FF00, .littleEndian))]
        let farOffsetData = Data(tiffHeader(.littleEndian) + ifdBytes(farOffset, .littleEndian))
        XCTAssertEqual(reader.readTIFF(farOffsetData)?.hasIdentity, false)
    }

    func testTrimsNulPaddingAndWhitespace() {
        let entries = [
            Entry(tag: 0x010F, type: 2, count: 8, value: u32(38, .littleEndian)),
            Entry(tag: 0x0110, type: 2, count: 4, value: [0x20, 0x58, 0x20, 0x00]), // " X \0"
        ]
        let data = Data(
            tiffHeader(.littleEndian)
                + ifdBytes(entries, .littleEndian)
                + Array("Canon\0\0\0".utf8)
        )

        let fields = reader.readTIFF(data)

        XCTAssertEqual(fields?.make, "Canon")
        XCTAssertEqual(fields?.model, "X")
    }

    func testReadsBareIFDWithNonZeroOffsetsBase() {
        // Mimics a vendor atom (Fuji MVTG / Casio QVMI): 16 bytes of junk,
        // then an IFD whose value offsets are relative to the atom base.
        let junk = [UInt8](repeating: 0xAA, count: 16)
        let entries = [
            Entry(tag: 0x010F, type: 2, count: 6, value: u32(18, .littleEndian)), // 18 = IFD size (2+12+4)
        ]
        let data = Data(junk + ifdBytes(entries, .littleEndian) + Array("CASIO\0".utf8))

        let fields = reader.readIFD(in: data, at: 16, byteOrder: .littleEndian, offsetsBase: 16)

        XCTAssertEqual(fields.make, "CASIO")
    }

    func testReadsExifFromJPEGAPP1() {
        let tiff = tiffHeader(.littleEndian) + ifdBytes(
            [Entry(tag: 0x0110, type: 2, count: 3, value: [0x47, 0x52, 0x00, 0x00])], // "GR\0"
            .littleEndian
        )
        let jpeg = jpegBytes(segments: [
            app(marker: 0xE0, payload: Array("JFIF\0".utf8)),
            app(marker: 0xE1, payload: Array("Exif\0\0".utf8) + tiff),
        ])

        XCTAssertEqual(reader.readJPEG(Data(jpeg))?.model, "GR")
    }

    func testSkipsNonExifAPP1Segments() {
        let tiff = tiffHeader(.littleEndian) + ifdBytes(
            [Entry(tag: 0x0110, type: 2, count: 3, value: [0x47, 0x52, 0x00, 0x00])],
            .littleEndian
        )
        let jpeg = jpegBytes(segments: [
            app(marker: 0xE1, payload: Array("http://ns.adobe.com/xap/1.0/\0<x/>".utf8)),
            app(marker: 0xE1, payload: Array("Exif\0\0".utf8) + tiff),
        ])

        XCTAssertEqual(reader.readJPEG(Data(jpeg))?.model, "GR")
    }

    func testReturnsNilForJPEGWithoutExifAPP1() {
        let noAPP1 = jpegBytes(segments: [app(marker: 0xE0, payload: Array("JFIF\0".utf8))])
        XCTAssertNil(reader.readJPEG(Data(noAPP1)))

        XCTAssertNil(reader.readJPEG(Data("not a jpeg at all".utf8)))
        XCTAssertNil(reader.readJPEG(Data()))
    }

    private struct Entry {
        let tag: UInt16
        let type: UInt16
        let count: UInt32
        let value: [UInt8]
    }

    private func u16(_ value: UInt16, _ order: ExifByteOrder) -> [UInt8] {
        order == .bigEndian
            ? [UInt8(value >> 8), UInt8(value & 0xFF)]
            : [UInt8(value & 0xFF), UInt8(value >> 8)]
    }

    private func u32(_ value: UInt32, _ order: ExifByteOrder) -> [UInt8] {
        let bytes = [
            UInt8(value >> 24),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF),
        ]
        return order == .bigEndian ? bytes : bytes.reversed()
    }

    private func tiffHeader(
        _ order: ExifByteOrder,
        magic: UInt16 = 0x2A,
        ifd0Offset: UInt32 = 8
    ) -> [UInt8] {
        (order == .bigEndian ? [0x4D, 0x4D] : [0x49, 0x49])
            + u16(magic, order)
            + u32(ifd0Offset, order)
    }

    private func ifdBytes(_ entries: [Entry], _ order: ExifByteOrder) -> [UInt8] {
        var bytes = u16(UInt16(entries.count), order)
        for entry in entries {
            precondition(entry.value.count == 4, "IFD entry value field must be 4 bytes")
            bytes += u16(entry.tag, order) + u16(entry.type, order) + u32(entry.count, order) + entry.value
        }
        bytes += u32(0, order) // next-IFD terminator
        return bytes
    }

    private func app(marker: UInt8, payload: [UInt8]) -> [UInt8] {
        [0xFF, marker] + u16(UInt16(payload.count + 2), .bigEndian) + payload
    }

    private func jpegBytes(segments: [[UInt8]]) -> [UInt8] {
        [0xFF, 0xD8] + segments.flatMap { $0 } + [0xFF, 0xD9]
    }
}
