import Foundation
import XCTest
@testable import FyluroCore

final class MinoltaMRWIdentityReaderTests: XCTestCase {
    private var tempDirectory: URL!
    private let reader = MinoltaMRWIdentityReader()

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mrw-identity-reader-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
    }

    func testReadsEmbeddedTIFFFromTTWSegmentBigEndian() throws {
        let tiff = minimalTIFF(make: "Konica Minolta Camera, Inc.", model: "DiMAGE A2", order: .bigEndian)
        let ttw = segment(tag: "\0TTW", payload: Data(tiff), order: .bigEndian)
        let prd = segment(tag: "\0PRD", payload: Data(repeating: 0, count: 8), order: .bigEndian)
        let body = ttw + prd
        let file = mrwHeader(magic: "\0MRM", blockLength: UInt32(body.count), order: .bigEndian) + body

        let fileURL = try writeFile(file, name: "sample.mrw")

        let decoded = reader.identity(for: fileURL)

        XCTAssertEqual(decoded?.make, "Konica Minolta Camera, Inc.")
        XCTAssertEqual(decoded?.model, "DiMAGE A2")
    }

    func testSkipsOverNonTTWSegmentsToFindTTW() throws {
        // Model string is deliberately >4 bytes (+ NUL): a TIFF ASCII value
        // of 4 bytes or fewer is stored inline in the entry's value field
        // per the real TIFF spec (see ExifIFDFieldReader.asciiValue), not as
        // an out-of-line offset -- this helper only builds the offset form.
        let tiff = minimalTIFF(make: nil, model: "DiMAGE X", order: .littleEndian)
        let prd = segment(tag: "\0PRD", payload: Data(repeating: 0xAA, count: 12), order: .littleEndian)
        let wbg = segment(tag: "\0WBG", payload: Data(repeating: 0xBB, count: 20), order: .littleEndian)
        let ttw = segment(tag: "\0TTW", payload: Data(tiff), order: .littleEndian)
        let body = prd + wbg + ttw
        // "\0MRI" magic -> little-endian.
        let file = mrwHeader(magic: "\0MRI", blockLength: UInt32(body.count), order: .littleEndian) + body

        let fileURL = try writeFile(file, name: "sample.mrw")

        XCTAssertEqual(reader.identity(for: fileURL)?.model, "DiMAGE X")
    }

    func testReturnsNilWhenNoTTWSegmentPresent() throws {
        let prd = segment(tag: "\0PRD", payload: Data(repeating: 0, count: 8), order: .bigEndian)
        let file = mrwHeader(magic: "\0MRM", blockLength: UInt32(prd.count), order: .bigEndian) + prd

        let fileURL = try writeFile(file, name: "sample.mrw")

        XCTAssertNil(reader.identity(for: fileURL))
    }

    func testReturnsNilForBadMagic() throws {
        let fileURL = try writeFile(Data("\0XXX".utf8) + Data(repeating: 0, count: 20), name: "sample.mrw")

        XCTAssertNil(reader.identity(for: fileURL))
    }

    /// A segment claiming a length that runs past the declared block end
    /// must stop cleanly, not read out of bounds (RT-P0-12 style guard).
    func testStopsOnSegmentLengthExceedingBlockBounds() throws {
        var body = Data("\0TTW".utf8)
        body.append(contentsOf: withUnsafeBytes(of: UInt32(0xFFFF_FFFF).bigEndian) { Array($0) })
        let file = mrwHeader(magic: "\0MRM", blockLength: UInt32(body.count), order: .bigEndian) + body

        let fileURL = try writeFile(file, name: "sample.mrw")

        XCTAssertNil(reader.identity(for: fileURL))
    }

    // MARK: - Helpers

    private func mrwHeader(magic: String, blockLength: UInt32, order: ExifByteOrder) -> Data {
        var data = Data(magic.utf8)
        data.append(u32(blockLength, order))
        return data
    }

    private func segment(tag: String, payload: Data, order: ExifByteOrder) -> Data {
        var data = Data(tag.utf8)
        data.append(u32(UInt32(payload.count), order))
        data.append(payload)
        return data
    }

    private func u32(_ value: UInt32, _ order: ExifByteOrder) -> Data {
        let bytes = [UInt8(value >> 24), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
        return Data(order == .bigEndian ? bytes : bytes.reversed())
    }

    private func u16(_ value: UInt16, _ order: ExifByteOrder) -> [UInt8] {
        order == .bigEndian ? [UInt8(value >> 8), UInt8(value & 0xFF)] : [UInt8(value & 0xFF), UInt8(value >> 8)]
    }

    private func minimalTIFF(make: String?, model: String, order: ExifByteOrder) -> [UInt8] {
        var entries: [(tag: UInt16, bytes: [UInt8])] = []
        var tail: [UInt8] = []
        var tailOffset = 8 + 2 + 12 * (make == nil ? 1 : 2) + 4

        if let make {
            let bytes = Array(make.utf8) + [0x00]
            entries.append((0x010F, u16(0x010F, order) + u16(2, order) + u32(UInt32(bytes.count), order).map { $0 }
                + u32(UInt32(tailOffset), order).map { $0 }))
            tail += bytes
            tailOffset += bytes.count
        }
        let modelBytes = Array(model.utf8) + [0x00]
        entries.append((0x0110, u16(0x0110, order) + u16(2, order) + u32(UInt32(modelBytes.count), order).map { $0 }
            + u32(UInt32(tailOffset), order).map { $0 }))
        tail += modelBytes

        var bytes: [UInt8] = order == .bigEndian ? [0x4D, 0x4D] : [0x49, 0x49]
        bytes += u16(0x2A, order) + u32(8, order).map { $0 }
        bytes += u16(UInt16(entries.count), order)
        for entry in entries { bytes += entry.bytes }
        bytes += u32(0, order).map { $0 }
        bytes += tail
        return bytes
    }

    private func writeFile(_ data: Data, name: String) throws -> URL {
        let url = tempDirectory.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }
}
