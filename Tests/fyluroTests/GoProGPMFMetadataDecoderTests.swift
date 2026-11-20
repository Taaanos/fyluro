import Foundation
import XCTest
@testable import FyluroCore

final class GoProGPMFMetadataDecoderTests: XCTestCase {
    func testDecodesModelFromMINFKey() {
        let entry = klvEntry(key: "MINF", type: "c", value: Data("HERO10 Black".utf8))

        let decoded = GoProGPMFMetadataDecoder().decode(entry)

        XCTAssertEqual(decoded.make, "GoPro")
        XCTAssertEqual(decoded.model, "HERO10 Black")
        XCTAssertNil(decoded.serial)
    }

    func testDecodesSerialFromCASNKey() {
        let entry = klvEntry(key: "CASN", type: "c", value: Data("TESTSERIAL0002".utf8))

        let decoded = GoProGPMFMetadataDecoder().decode(entry)

        XCTAssertEqual(decoded.serial, "TESTSERIAL0002")
    }

    func testRecursesIntoNestedContainerToFindMINF() {
        let inner = klvEntry(key: "MINF", type: "c", value: Data("HERO10 Black".utf8))
        let container = containerEntry(key: "DEVC", payload: inner)

        let decoded = GoProGPMFMetadataDecoder().decode(container)

        XCTAssertEqual(decoded.model, "HERO10 Black")
    }

    func testReturnsNilsForUnrelatedPayload() {
        let entry = klvEntry(key: "DVNM", type: "c", value: Data("Global Settings".utf8))

        let decoded = GoProGPMFMetadataDecoder().decode(entry)

        XCTAssertNil(decoded.make)
        XCTAssertNil(decoded.model)
        XCTAssertNil(decoded.serial)
    }

    func testReturnsNilsForEmptyPayload() {
        let decoded = GoProGPMFMetadataDecoder().decode(Data())

        XCTAssertNil(decoded.make)
        XCTAssertNil(decoded.model)
        XCTAssertNil(decoded.serial)
    }

    func testDefendsAgainstOversizedElementCountClaim() {
        // Header claims 200*100 = 20,000 payload bytes but only 4 are present.
        var data = Data("MINF".utf8)
        data.append(UInt8(ascii: "c"))
        data.append(200) // element size
        data.append(contentsOf: [0x00, 0x64]) // count = 100 (big-endian)
        data.append(Data([0x41, 0x42, 0x43, 0x44]))

        let decoded = GoProGPMFMetadataDecoder().decode(data)

        XCTAssertNil(decoded.model)
    }

    func testSkipsNonStringTypeEvenIfKeyMatches() {
        var data = Data("MINF".utf8)
        data.append(UInt8(ascii: "L")) // uint32, not a string
        data.append(4)
        data.append(contentsOf: [0x00, 0x01])
        data.append(Data([0x00, 0x00, 0x00, 0x01]))

        let decoded = GoProGPMFMetadataDecoder().decode(data)

        XCTAssertNil(decoded.model)
    }

    // MARK: - Helpers

    /// Builds one leaf KLV entry: FourCC key, 1-char type, element size == the
    /// value's byte count, count == 1, 4-byte-aligned padding.
    private func klvEntry(key: String, type: String, value: Data) -> Data {
        var data = Data(key.utf8)
        data.append(type.utf8.first!)
        data.append(UInt8(value.count))
        data.append(contentsOf: [0x00, 0x01]) // count = 1
        data.append(value)
        let padding = (4 - (value.count % 4)) % 4
        data.append(Data(repeating: 0, count: padding))
        return data
    }

    /// Wraps `payload` as one nested-container KLV entry (type 0x00).
    private func containerEntry(key: String, payload: Data) -> Data {
        var data = Data(key.utf8)
        data.append(0x00) // container type
        data.append(1) // element size
        let count = payload.count
        data.append(contentsOf: [UInt8((count >> 8) & 0xFF), UInt8(count & 0xFF)])
        data.append(payload)
        let padding = (4 - (payload.count % 4)) % 4
        data.append(Data(repeating: 0, count: padding))
        return data
    }
}
