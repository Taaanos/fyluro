import Foundation
import XCTest
@testable import FyluroCore

final class PanasonicPANAMetadataDecoderTests: XCTestCase {
    private let decoder = PanasonicPANAMetadataDecoder()

    func testDecodesLeicaMakeAndModel() {
        var payload = Data("LEICA".utf8)
        payload.append(Data(repeating: 0, count: 0x16 - payload.count))
        payload.append(Data("Leica M11".utf8))
        payload.append(Data(repeating: 0, count: 4))

        let decoded = decoder.decode(payload)

        XCTAssertEqual(decoded.make, "LEICA")
        XCTAssertEqual(decoded.model, "Leica M11")
    }

    func testDecodesPanasonicModelAtPrimaryOffsetWithoutMake() {
        var payload = Data(repeating: 0, count: 0x04)
        payload.append(Data("DMC-GH6\0\0\0\0\0\0\0\0\0".utf8))

        let decoded = decoder.decode(payload)

        XCTAssertEqual(decoded.make, "Panasonic")
        XCTAssertEqual(decoded.model, "DMC-GH6")
    }

    func testFallsBackToSecondaryModelOffsetForFZ1000Layout() {
        var payload = Data(repeating: 0, count: 0x0C)
        payload.append(Data("DC-FZ1000M2\0\0\0\0\0".utf8))

        let decoded = decoder.decode(payload)

        XCTAssertEqual(decoded.model, "DC-FZ1000M2")
    }

    func testRejectsModelShorterThanMinimumLength() {
        // "GH\0..." -- fewer than 6 non-NUL leading bytes at 0x04, exactly
        // the garbage-field guard exiftool's own Condition encodes.
        var payload = Data(repeating: 0, count: 0x04)
        payload.append(Data("GH\0\0\0\0\0\0\0\0\0\0\0\0".utf8))

        XCTAssertNil(decoder.decode(payload).model)
    }

    func testReturnsNilForUnrecognizedPayload() {
        XCTAssertEqual(decoder.decode(Data(repeating: 0xFF, count: 8)).model, nil)
        XCTAssertNil(decoder.decode(Data()).make)
    }
}
