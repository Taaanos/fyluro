import Foundation
import XCTest
@testable import FyluroCore

final class SamsungSmtaMetadataDecoderTests: XCTestCase {
    func testExtractsModelFromMdlnSubBox() {
        let payload = fullBoxPayload([
            entry("saut", value: Data(repeating: 0x00, count: 6)),
            entry("mdln", value: Data("SM-A546B".utf8)),
        ])

        let decoded = SamsungSmtaMetadataDecoder().decode(payload)

        XCTAssertEqual(decoded.make, "Samsung")
        XCTAssertEqual(decoded.model, "SM-A546B")
        XCTAssertNil(decoded.serial)
    }

    func testReturnsNilWhenMdlnAbsent() {
        let payload = fullBoxPayload([
            entry("saut", value: Data(repeating: 0x00, count: 6)),
        ])

        let decoded = SamsungSmtaMetadataDecoder().decode(payload)

        XCTAssertNil(decoded.make)
        XCTAssertNil(decoded.model)
    }

    func testFindsMdlnRegardlessOfPrecedingEntries() {
        let payload = fullBoxPayload([
            entry("saut", value: Data(repeating: 0x00, count: 6)),
            entry("aaaa", value: Data(repeating: 0xFF, count: 4)),
            entry("mdln", value: Data("SM-S911B".utf8)),
        ])

        let decoded = SamsungSmtaMetadataDecoder().decode(payload)

        XCTAssertEqual(decoded.model, "SM-S911B")
    }

    func testReturnsNilForPayloadShorterThanFullBoxHeader() {
        let decoded = SamsungSmtaMetadataDecoder().decode(Data([0x00, 0x00]))

        XCTAssertNil(decoded.model)
    }

    func testDefendsAgainstOversizedDeclaredEntrySize() {
        var payload = Data([0x00, 0x00, 0x00, 0x00]) // FullBox prefix
        payload.append(contentsOf: withUnsafeBytes(of: UInt32(9999).bigEndian) { Array($0) })
        payload.append(Data("mdln".utf8))
        payload.append(Data("SM-A546B".utf8)) // far fewer bytes than declared

        let decoded = SamsungSmtaMetadataDecoder().decode(payload)

        XCTAssertNil(decoded.model)
    }

    private func fullBoxPayload(_ entries: [Data]) -> Data {
        var data = Data([0x00, 0x00, 0x00, 0x00])
        entries.forEach { data.append($0) }
        return data
    }

    private func entry(_ fourcc: String, value: Data) -> Data {
        var data = Data()
        let size = UInt32(8 + value.count)
        data.append(contentsOf: withUnsafeBytes(of: size.bigEndian) { Array($0) })
        data.append(Data(fourcc.utf8))
        data.append(value)
        return data
    }
}
