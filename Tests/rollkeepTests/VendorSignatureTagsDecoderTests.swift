import Foundation
import XCTest
@testable import RollKeepCore

final class VendorSignatureTagsDecoderTests: XCTestCase {
    private let decoder = VendorSignatureTagsDecoder()

    func testDecodesFujiFilmMakeAndModel() {
        var payload = Data("FUJIFILM DIGITAL CAMERA\0".utf8)
        payload.append(Data(repeating: 0, count: 0x18 - payload.count))
        payload.append(Data("X-T5\0\0\0\0\0\0\0\0\0\0\0\0".utf8))

        let decoded = decoder.decode(payload)

        XCTAssertEqual(decoded.make, "FUJIFILM DIGITAL CAMERA")
        XCTAssertEqual(decoded.model, "X-T5")
    }

    func testDecodesKodakAtItsOwnModelOffset() {
        var payload = Data("EASTMAN KODAK COMPANY".utf8)
        payload.append(Data(repeating: 0, count: 0x16 - payload.count))
        payload.append(Data("KODAK P880 ZOOM DIGITAL CAMERA\0".utf8))

        XCTAssertEqual(decoder.decode(payload).model, "KODAK P880 ZOOM DIGITAL CAMERA")
    }

    /// Pentax's table has no Model field at all in this atom -- the real
    /// exiftool corpus sample (t/images/QuickTime.mov) resolves to
    /// make="PENTAX DIGITAL CAMERA", model=nil, which this must match.
    func testPentaxYieldsMakeOnlyNoModelField() {
        let payload = Data("PENTAX DIGITAL CAMERA\0".utf8) + Data(repeating: 0, count: 40)

        let decoded = decoder.decode(payload)

        XCTAssertEqual(decoded.make, "PENTAX DIGITAL CAMERA")
        XCTAssertNil(decoded.model)
    }

    func testLongerKonicaMinoltaSignatureWinsOverMinoltaPrefix() {
        let payload = Data("KONICA MINOLTA DIGITAL CAMERA\0".utf8) + Data(repeating: 0, count: 20)

        // Regression guard: "MINOLTA DIGITAL CAMERA" is a substring-adjacent
        // signature: matching layouts must be tried longest-first or this
        // would misfire on the shorter Minolta entry.
        XCTAssertEqual(decoder.decode(payload).make, "KONICA MINOLTA DIGITAL CAMERA")
    }

    func testReturnsNilForUnknownSignature() {
        let decoded = decoder.decode(Data("SOME OTHER VENDOR\0".utf8))

        XCTAssertNil(decoded.make)
        XCTAssertNil(decoded.model)
    }

    func testStopsModelRunAtFirstNULOrNonPrintableByte() {
        var payload = Data("NIKON DIGITAL CAMERA\0".utf8)
        payload.append(Data(repeating: 0, count: 0x18 - payload.count))
        payload.append(Data("COOLPIX\0\u{01}\u{00}garbage".utf8))

        XCTAssertEqual(decoder.decode(payload).model, "COOLPIX")
    }

    func testHandlesPayloadShorterThanModelOffsetGracefully() {
        let payload = Data("SAMSUNG DIGITAL CAMERA\0".utf8) // shorter than 0x18 + field

        let decoded = decoder.decode(payload)

        XCTAssertEqual(decoded.make, "SAMSUNG DIGITAL CAMERA")
        XCTAssertNil(decoded.model)
    }
}
