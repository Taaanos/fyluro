import Foundation
import XCTest
@testable import FyluroCore

final class CanonCR3IdentityReaderTests: XCTestCase {
    private var tempDirectory: URL!
    private let reader = CanonCR3IdentityReader()

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cr3-identity-reader-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
    }

    func testReadsMakeModelFromMoovLevelCanonUuidCMT1() throws {
        let ifd0 = tiff(entries: [
            entry(tag: 0x010F, count: 6, value: u32(38, .bigEndian)),
            entry(tag: 0x0110, count: 8, value: u32(44, .bigEndian)),
        ], order: .bigEndian, tail: Array("Canon\0".utf8) + Array("EOS M50\0".utf8))
        let uuidContent = box("CMT1", payload: Data(ifd0))
        let uuidPayload = CanonVideoMetadata.movieUuidUsertype + uuidContent
        let uuid = box("uuid", payload: uuidPayload)
        let moov = box("moov", payload: uuid)
        let ftyp = box("ftyp", payload: Data("crx \u{0}\u{0}\u{0}\u{0}".utf8))
        let fileURL = try writeFile(ftyp + moov, name: "sample.cr3")

        let decoded = reader.identity(for: fileURL)

        XCTAssertEqual(decoded?.make, "Canon")
        XCTAssertEqual(decoded?.model, "EOS M50")
    }

    func testReturnsNilWhenNoMoovBox() throws {
        let fileURL = try writeFile(box("ftyp", payload: Data("crx ".utf8)), name: "sample.cr3")

        XCTAssertNil(reader.identity(for: fileURL))
    }

    func testReturnsNilWhenNoCanonUuidUnderMoov() throws {
        let moov = box("moov", payload: box("udta", payload: Data()))
        let fileURL = try writeFile(moov, name: "sample.cr3")

        XCTAssertNil(reader.identity(for: fileURL))
    }

    func testReturnsNilForNonexistentFile() {
        let fileURL = tempDirectory.appendingPathComponent("missing.cr3")

        XCTAssertNil(reader.identity(for: fileURL))
    }

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

    private func entry(tag: UInt16, type: UInt16 = 2, count: UInt32, value: [UInt8]) -> Entry {
        Entry(tag: tag, type: type, count: count, value: value)
    }

    private func tiff(entries: [Entry], order: ExifByteOrder, tail: [UInt8]) -> [UInt8] {
        var bytes: [UInt8] = order == .bigEndian ? [0x4D, 0x4D] : [0x49, 0x49]
        bytes += u16(0x2A, order) + u32(8, order)
        bytes += u16(UInt16(entries.count), order)
        for item in entries {
            bytes += u16(item.tag, order) + u16(item.type, order) + u32(item.count, order) + item.value
        }
        bytes += u32(0, order)
        bytes += tail
        return bytes
    }

    private func box(_ type: String, payload: Data) -> Data {
        var data = Data()
        data.append(contentsOf: withUnsafeBytes(of: UInt32(8 + payload.count).bigEndian) { Array($0) })
        data.append(Data(type.unicodeScalars.map { UInt8($0.value & 0xFF) }))
        data.append(payload)
        return data
    }

    private func writeFile(_ data: Data, name: String) throws -> URL {
        let url = tempDirectory.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }
}
