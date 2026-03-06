import Foundation
import XCTest
@testable import rollkeep

final class ExifDateParserTests: XCTestCase {
    func testParsesExifDateTimeWithExplicitOffset() throws {
        let parser = ExifDateParser()
        let parsed = try XCTUnwrap(parser.parse("2025:01:15 12:34:56+02:00"))

        XCTAssertEqual(Int(parsed.timeIntervalSince1970), 1_736_937_296)
    }

    func testParsesExifDateTimeWithoutOffsetUsingLocalTimeZoneFormat() throws {
        let parser = ExifDateParser()
        let parsed = parser.parse("2025:01:15 12:34:56")

        XCTAssertNotNil(parsed)
    }

    func testReturnsNilForInvalidExifDateTime() {
        let parser = ExifDateParser()

        XCTAssertNil(parser.parse("not-a-date"))
    }
}
