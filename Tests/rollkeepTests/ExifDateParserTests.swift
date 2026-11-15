import Foundation
import XCTest
@testable import RollKeepCore

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

    func testParsesExifDateTimeDuringDSTSpringForwardGap() throws {
        let newYork = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let nyParser = ExifDateParser(timeZone: newYork)

        // America/New_York skipped 02:00 -> 03:00 on 2025-03-09.
        let parsedNY = try XCTUnwrap(nyParser.parse("2025:03:09 02:30:00"))
        var nyCalendar = Calendar(identifier: .gregorian)
        nyCalendar.timeZone = newYork
        let nyComponents = nyCalendar.dateComponents([.year, .month, .day], from: parsedNY)
        XCTAssertEqual(nyComponents.year, 2025)
        XCTAssertEqual(nyComponents.month, 3)
        XCTAssertEqual(nyComponents.day, 9)

        let athens = try XCTUnwrap(TimeZone(identifier: "Europe/Athens"))
        let athensParser = ExifDateParser(timeZone: athens)

        // Europe/Athens skipped 03:00 -> 04:00 on 2025-03-30.
        let parsedAthens = try XCTUnwrap(athensParser.parse("2025:03:30 03:30:00"))
        var athensCalendar = Calendar(identifier: .gregorian)
        athensCalendar.timeZone = athens
        let athensComponents = athensCalendar.dateComponents([.year, .month, .day], from: parsedAthens)
        XCTAssertEqual(athensComponents.year, 2025)
        XCTAssertEqual(athensComponents.month, 3)
        XCTAssertEqual(athensComponents.day, 30)
    }

    func testRejectsZeroAndOutOfRangeExifDates() throws {
        let ny = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let parser = ExifDateParser(timeZone: ny)

        // Dead camera battery timestamps
        XCTAssertNil(parser.parse("0000:00:00 00:00:00"))
        XCTAssertNil(parser.parse("0000:01:01 12:00:00"))
        XCTAssertNil(parser.parse("0000:00:00 00:00:00+00:00"))

        // Out-of-range components
        XCTAssertNil(parser.parse("2025:00:15 12:00:00"))
        XCTAssertNil(parser.parse("2025:13:15 12:00:00"))
        XCTAssertNil(parser.parse("2025:01:00 12:00:00"))
        XCTAssertNil(parser.parse("2025:01:32 12:00:00"))
        XCTAssertNil(parser.parse("2025:04:31 12:00:00"))
        XCTAssertNil(parser.parse("2025:02:29 12:00:00"))
        XCTAssertNil(parser.parse("2025:01:15 24:00:00"))
        XCTAssertNil(parser.parse("2025:01:15 12:60:00"))
        XCTAssertNil(parser.parse("2025:01:15 12:00:60"))

        // Valid leap day is accepted
        XCTAssertNotNil(parser.parse("2024:02:29 12:00:00"))
    }
}
