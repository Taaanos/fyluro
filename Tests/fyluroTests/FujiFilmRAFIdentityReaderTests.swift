import Foundation
import XCTest
@testable import FyluroCore

final class FujiFilmRAFIdentityReaderTests: XCTestCase {
    private var tempDirectory: URL!
    private let reader = FujiFilmRAFIdentityReader()

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("raf-identity-reader-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
    }

    func testReadsIdentityFromEmbeddedJPEGPreviewAtHeaderOffsets() throws {
        let jpeg = jpegWithExifModel("FinePix S5Pro", make: "FUJIFILM")
        // 0x70-byte header: signature at 0, jpeg [offset,length] uint32 pair
        // (big-endian) at 0x54/0x58.
        var header = Data("FUJIFILM".utf8)
        header.append(Data(repeating: 0, count: 0x70 - header.count))
        let jpegOffset: UInt32 = 0x70
        header.replaceSubrange(0x54..<0x58, with: u32(jpegOffset, .bigEndian))
        header.replaceSubrange(0x58..<0x5C, with: u32(UInt32(jpeg.count), .bigEndian))

        let fileURL = try writeFile(header + Data(jpeg), name: "sample.raf")

        let decoded = reader.identity(for: fileURL)

        XCTAssertEqual(decoded?.make, "FUJIFILM")
        XCTAssertEqual(decoded?.model, "FinePix S5Pro")
    }

    func testReturnsNilWhenSignatureMissing() throws {
        let fileURL = try writeFile(Data(repeating: 0, count: 0x70), name: "sample.raf")

        XCTAssertNil(reader.identity(for: fileURL))
    }

    func testReturnsNilWhenHeaderTruncated() throws {
        let fileURL = try writeFile(Data("FUJIFILM".utf8), name: "sample.raf")

        XCTAssertNil(reader.identity(for: fileURL))
    }

    func testReturnsNilWhenJPEGLengthExceedsCap() throws {
        var header = Data("FUJIFILM".utf8)
        header.append(Data(repeating: 0, count: 0x70 - header.count))
        header.replaceSubrange(0x54..<0x58, with: u32(0x70, .bigEndian))
        header.replaceSubrange(0x58..<0x5C, with: u32(0xFFFF_FFFF, .bigEndian)) // hostile huge length

        let fileURL = try writeFile(header, name: "sample.raf")

        XCTAssertNil(reader.identity(for: fileURL))
    }

    func testReturnsNilWhenJPEGOffsetOrLengthIsZero() throws {
        var header = Data("FUJIFILM".utf8)
        header.append(Data(repeating: 0, count: 0x70 - header.count))
        // offset/length left as zero.
        let fileURL = try writeFile(header, name: "sample.raf")

        XCTAssertNil(reader.identity(for: fileURL))
    }

    // MARK: - Helpers

    private func u32(_ value: UInt32, _ order: ExifByteOrder) -> Data {
        let bytes = [UInt8(value >> 24), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
        return Data(order == .bigEndian ? bytes : bytes.reversed())
    }

    private func u16(_ value: UInt16, _ order: ExifByteOrder) -> [UInt8] {
        order == .bigEndian ? [UInt8(value >> 8), UInt8(value & 0xFF)] : [UInt8(value & 0xFF), UInt8(value >> 8)]
    }

    private func jpegWithExifModel(_ model: String, make: String) -> [UInt8] {
        let makeBytes = Array(make.utf8) + [0x00]
        let modelBytes = Array(model.utf8) + [0x00]
        // IFD0: 2 entries -> tail starts at 8 + 2 + 24 + 4 = 38.
        var tiffBytes: [UInt8] = [0x49, 0x49] + u16(0x2A, .littleEndian)
        tiffBytes += u32(8, .littleEndian).map { $0 }
        tiffBytes += u16(2, .littleEndian)
        tiffBytes += u16(0x010F, .littleEndian) + u16(2, .littleEndian)
        tiffBytes += u32(UInt32(makeBytes.count), .littleEndian).map { $0 }
        tiffBytes += u32(38, .littleEndian).map { $0 }
        tiffBytes += u16(0x0110, .littleEndian) + u16(2, .littleEndian)
        tiffBytes += u32(UInt32(modelBytes.count), .littleEndian).map { $0 }
        tiffBytes += u32(UInt32(38 + makeBytes.count), .littleEndian).map { $0 }
        tiffBytes += u32(0, .littleEndian).map { $0 } // next-IFD
        tiffBytes += makeBytes + modelBytes

        let exifPayload = Array("Exif\0\0".utf8) + tiffBytes
        let app1 = [0xFF, 0xE1] + u16(UInt16(exifPayload.count + 2), .bigEndian) + exifPayload
        return [0xFF, 0xD8] + app1 + [0xFF, 0xD9]
    }

    private func writeFile(_ data: Data, name: String) throws -> URL {
        let url = tempDirectory.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }
}
