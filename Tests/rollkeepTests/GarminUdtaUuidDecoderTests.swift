import Foundation
import XCTest
@testable import RollKeepCore

final class GarminUdtaUuidDecoderTests: XCTestCase {
    private let decoder = GarminUdtaUuidDecoder()

    func testDecodesModelAndInfersGarminMake() {
        var content = Data(repeating: 0, count: 8) // unknown header
        content.append(0x08) // length byte: 8
        content.append(Data("VIRB 360".utf8))

        let decoded = decoder.decode(content)

        XCTAssertEqual(decoded.make, "Garmin")
        XCTAssertEqual(decoded.model, "VIRB 360")
    }

    func testReturnsNilWhenLengthExceedsAvailableBytes() {
        var content = Data(repeating: 0, count: 8)
        content.append(0x14) // claims 20 bytes but none follow
        XCTAssertNil(decoder.decode(content).model)
    }

    func testReturnsNilWhenContentTooShortToReadLength() {
        XCTAssertNil(decoder.decode(Data(repeating: 0, count: 5)).model)
        XCTAssertNil(decoder.decode(Data()).model)
    }

    func testReturnsNilForZeroLength() {
        var content = Data(repeating: 0, count: 8)
        content.append(0x00)
        XCTAssertNil(decoder.decode(content).model)
    }
}
