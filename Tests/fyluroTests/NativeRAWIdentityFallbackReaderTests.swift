import Foundation
import XCTest
@testable import FyluroCore

final class NativeRAWIdentityFallbackReaderTests: XCTestCase {
    private var tempDirectory: URL!
    private let reader = NativeRAWIdentityFallbackReader()

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("native-raw-fallback-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
    }

    func testGenericTIFFPathHandlesStandardMagicRegardlessOfExtension() throws {
        let tiff = minimalTIFF(make: "NIKON CORPORATION", model: "NIKON D850", magic: 0x2A, order: .bigEndian)
        let fileURL = try writeFile(Data(tiff), name: "sample.nef")

        let decoded = reader.identity(for: fileURL)

        XCTAssertEqual(decoded?.make, "NIKON CORPORATION")
        XCTAssertEqual(decoded?.model, "NIKON D850")
    }

    func testGenericTIFFPathHandlesRW2MagicVariant() throws {
        let tiff = minimalTIFF(make: nil, model: "DMC-GH6", magic: 0x55, order: .littleEndian)
        let fileURL = try writeFile(Data(tiff), name: "sample.rw2")

        XCTAssertEqual(reader.identity(for: fileURL)?.model, "DMC-GH6")
    }

    func testCR3ExtensionDispatchesToCanonUuidPathNotGenericTIFF() throws {
        // A .cr3 file is never a bare TIFF (it's ISO-BMFF); with no moov/uuid
        // present at all, the dispatcher must return nil rather than
        // (incorrectly) attempting a generic TIFF read on BMFF bytes.
        let fileURL = try writeFile(Data("not a tiff or bmff".utf8), name: "sample.cr3")

        XCTAssertNil(reader.identity(for: fileURL))
    }

    func testRAFExtensionDispatchesToFujiFilmPathNotGenericTIFF() throws {
        let fileURL = try writeFile(Data("not a raf file".utf8), name: "sample.raf")

        XCTAssertNil(reader.identity(for: fileURL))
    }

    func testMRWExtensionDispatchesToMinoltaPathNotGenericTIFF() throws {
        let fileURL = try writeFile(Data("not an mrw file".utf8), name: "sample.mrw")

        XCTAssertNil(reader.identity(for: fileURL))
    }

    func testReturnsNilForGarbageWithGenericExtension() throws {
        let fileURL = try writeFile(Data("just some random bytes, not TIFF at all".utf8), name: "sample.arw")

        XCTAssertNil(reader.identity(for: fileURL))
    }

    func testExtensionMatchingIsCaseInsensitive() throws {
        let tiff = minimalTIFF(make: "Canon", model: nil, magic: 0x2A, order: .littleEndian)
        let fileURL = try writeFile(Data(tiff), name: "SAMPLE.CR2")

        XCTAssertEqual(reader.identity(for: fileURL)?.make, "Canon")
    }

    // MARK: - Helpers

    private func u32(_ value: UInt32, _ order: ExifByteOrder) -> [UInt8] {
        let bytes = [UInt8(value >> 24), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
        return order == .bigEndian ? bytes : bytes.reversed()
    }

    private func u16(_ value: UInt16, _ order: ExifByteOrder) -> [UInt8] {
        order == .bigEndian ? [UInt8(value >> 8), UInt8(value & 0xFF)] : [UInt8(value & 0xFF), UInt8(value >> 8)]
    }

    private func minimalTIFF(make: String?, model: String?, magic: UInt16, order: ExifByteOrder) -> [UInt8] {
        var entries: [(tag: UInt16, value: [UInt8])] = []
        var tail: [UInt8] = []
        let entryCount = (make != nil ? 1 : 0) + (model != nil ? 1 : 0)
        var tailOffset = 8 + 2 + 12 * entryCount + 4

        if let make {
            let bytes = Array(make.utf8) + [0x00]
            entries.append((0x010F, u16(0x010F, order) + u16(2, order) + u32(UInt32(bytes.count), order)
                + u32(UInt32(tailOffset), order)))
            tail += bytes
            tailOffset += bytes.count
        }
        if let model {
            let bytes = Array(model.utf8) + [0x00]
            entries.append((0x0110, u16(0x0110, order) + u16(2, order) + u32(UInt32(bytes.count), order)
                + u32(UInt32(tailOffset), order)))
            tail += bytes
        }

        var bytes: [UInt8] = order == .bigEndian ? [0x4D, 0x4D] : [0x49, 0x49]
        bytes += u16(magic, order) + u32(8, order)
        bytes += u16(UInt16(entries.count), order)
        for entry in entries { bytes += entry.value }
        bytes += u32(0, order)
        bytes += tail
        return bytes
    }

    private func writeFile(_ data: Data, name: String) throws -> URL {
        let url = tempDirectory.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }
}
