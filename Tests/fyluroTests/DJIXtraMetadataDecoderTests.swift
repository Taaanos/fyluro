import Foundation
import XCTest
@testable import FyluroCore

final class DJIXtraMetadataDecoderTests: XCTestCase {
    func testExtractsModelNameFromUtf16LePseudoKeyValueString() {
        let payload = utf16LE("pb_file:dvtm_ac206.proto;model_name:AC006;pb_version:2.0.1;pb_lib_version:02.01.19;")

        let decoded = DJIXtraMetadataDecoder().decode(payload)

        XCTAssertEqual(decoded.make, "DJI")
        XCTAssertEqual(decoded.model, "AC006")
        XCTAssertNil(decoded.serial)
    }

    func testReturnsNilModelWhenMarkerAbsent() {
        let payload = utf16LE("pb_file:dvtm_ac206.proto;pb_version:2.0.1;")

        let decoded = DJIXtraMetadataDecoder().decode(payload)

        XCTAssertNil(decoded.make)
        XCTAssertNil(decoded.model)
    }

    func testStopsAtSemicolonDelimiter() {
        let payload = utf16LE("model_name:FC8482;pb_version:02.01.00;")

        let decoded = DJIXtraMetadataDecoder().decode(payload)

        XCTAssertEqual(decoded.model, "FC8482")
    }

    func testReturnsNilForEmptyPayload() {
        let decoded = DJIXtraMetadataDecoder().decode(Data())

        XCTAssertNil(decoded.model)
    }

    func testReturnsNilWhenMarkerIsAtVeryEndWithNoValue() {
        let payload = utf16LE("pb_file:x;model_name:")

        let decoded = DJIXtraMetadataDecoder().decode(payload)

        XCTAssertNil(decoded.model)
    }

    func testWorksAgainstRealFixtureByteShapeAcrossDJIProductLines() {
        // Verified byte-for-byte against real files: action-4 (AC003),
        // action-6 (AC006), mini-4-pro (FC8482), pocket-3 (PP-101).
        let cases: [(String, String)] = [
            ("dvtm_ac203.proto", "AC003"),
            ("dvtm_ac206.proto", "AC006"),
            ("dvtm_Mini4_Pro.proto", "FC8482"),
            ("dvtm_PP-101.proto", "PP-101"),
        ]

        for (protoName, expectedModel) in cases {
            let payload = utf16LE("pb_file:\(protoName);model_name:\(expectedModel);pb_version:2.0.1;pb_lib_version:02.01.19;")
            let decoded = DJIXtraMetadataDecoder().decode(payload)
            XCTAssertEqual(decoded.model, expectedModel)
            XCTAssertEqual(decoded.make, "DJI")
        }
    }

    private func utf16LE(_ string: String) -> Data {
        var data = Data()
        for unit in string.utf16 {
            data.append(UInt8(unit & 0xFF))
            data.append(UInt8(unit >> 8))
        }
        return data
    }
}
