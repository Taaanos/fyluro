import Foundation
import XCTest
@testable import FyluroCore

final class UdtaDirectTagDecodersTests: XCTestCase {
    func testDecodesCopyrightSymbolMakeWithInternationalTextHeader() {
        let payload = internationalText("Canon")
        let decoded = UdtaDirectTagDecoders.registryEntries["\u{A9}mak"]!(payload)

        XCTAssertEqual(decoded.make, "Canon")
    }

    func testFallsBackToRawTextWhenInternationalHeaderAbsent() {
        // Some writers omit the [size][lang] header entirely.
        let payload = Data("Sony".utf8)
        let decoded = UdtaDirectTagDecoders.registryEntries["\u{A9}mod"]!(payload)

        XCTAssertEqual(decoded.model, "Sony")
    }

    func testDJIModelTagHasNoInternationalHeaderByDesign() {
        let decoded = UdtaDirectTagDecoders.registryEntries["\u{A9}mdl"]!(Data("DJI Osmo Action 6".utf8))

        XCTAssertEqual(decoded.model, "DJI Osmo Action 6")
    }

    func testRicohAtSignVariantTags() {
        XCTAssertEqual(UdtaDirectTagDecoders.registryEntries["@mak"]!(Data("RICOH".utf8)).make, "RICOH")
        XCTAssertEqual(UdtaDirectTagDecoders.registryEntries["@mod"]!(Data("THETA Z1".utf8)).model, "THETA Z1")
    }

    func testStripsCanonSixByteQuirkPrefixFromManuModl() {
        var payload = Data([0x00, 0x00, 0x00, 0x00, 0x15, 0xC7])
        payload.append(Data("Canon".utf8))
        XCTAssertEqual(UdtaDirectTagDecoders.registryEntries["manu"]!(payload).make, "Canon")

        var modlPayload = Data([0x00, 0x00, 0x00, 0x00, 0x15, 0xC7])
        modlPayload.append(Data("SX280 HS".utf8))
        XCTAssertEqual(UdtaDirectTagDecoders.registryEntries["modl"]!(modlPayload).model, "SX280 HS")
    }

    func testManuModlWithoutPrefixQuirkStillDecode() {
        // Samsung GT-S8530 writes these tags with no leading junk bytes.
        XCTAssertEqual(UdtaDirectTagDecoders.registryEntries["modl"]!(Data("GT-S8530".utf8)).model, "GT-S8530")
    }

    func testTrimsNulPaddingAndWhitespace() {
        let decoded = UdtaDirectTagDecoders.registryEntries["slno"]!(Data("SN123\0\0\0".utf8))

        XCTAssertEqual(decoded.serial, "SN123")
    }

    func testReturnsNilForEmptyOrAllNulPayload() {
        XCTAssertNil(UdtaDirectTagDecoders.registryEntries["\u{A9}mak"]!(Data()).make)
        XCTAssertNil(UdtaDirectTagDecoders.registryEntries["\u{A9}mak"]!(Data(repeating: 0, count: 4)).make)
    }

    func testFourCCsExposesEveryRegisteredKey() {
        XCTAssertEqual(UdtaDirectTagDecoders.fourCCs, Set(UdtaDirectTagDecoders.registryEntries.keys))
        XCTAssertTrue(UdtaDirectTagDecoders.fourCCs.contains("cmid"))
        XCTAssertTrue(UdtaDirectTagDecoders.fourCCs.contains("SNum"))
    }

    private func internationalText(_ value: String) -> Data {
        let text = Data(value.utf8)
        var data = Data()
        data.append(contentsOf: withUnsafeBytes(of: UInt16(text.count).bigEndian) { Array($0) })
        data.append(contentsOf: [0x00, 0x00]) // language
        data.append(text)
        return data
    }
}
