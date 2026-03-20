import XCTest
@testable import rollkeepLauncher

final class LauncherExecutionParsingRobustnessTests: XCTestCase {
    func testCLIOutputParserIgnoresMalformedAndPartialLines() {
        var parser = CLIOutputParser()

        let malformed = parser.parse(line: "{\"message\":")
        XCTAssertNil(malformed.phase)
        XCTAssertNil(malformed.result)
        XCTAssertNil(malformed.receiptPath)

        let partial = parser.parse(line: "{\"message\":\"scan_summary\"")
        XCTAssertNil(partial.phase)
        XCTAssertNil(partial.result)
        XCTAssertNil(partial.scannedCandidateCount)
    }

    func testCLIOutputParserIgnoresUnknownPayloadKeysWithoutFalseResult() {
        var parser = CLIOutputParser()
        let update = parser.parse(line: "{\"unknown\":\"value\",\"another\":42}")

        XCTAssertNil(update.phase)
        XCTAssertNil(update.result)
        XCTAssertNil(update.receiptPath)
        XCTAssertNil(update.failureReason)
    }

    func testReceiptEventParserIgnoresMalformedAndUnknownEventPayloads() {
        var parser = ReceiptEventParser()

        let malformed = parser.parse(line: "{\"event_type\":\"SCAN_SUMMARY\",\"data\":")
        XCTAssertNil(malformed.phase)
        XCTAssertNil(malformed.scannedCandidateCount)
        XCTAssertEqual(malformed.copiedIncrement, 0)
        XCTAssertNil(malformed.errorItem)

        let unknown = parser.parse(line: "{\"event_type\":\"SOMETHING_NEW\",\"phase\":\"mystery\",\"data\":{\"foo\":\"bar\"}}")
        XCTAssertNil(unknown.phase)
        XCTAssertNil(unknown.scannedCandidateCount)
        XCTAssertEqual(unknown.copiedIncrement, 0)
        XCTAssertEqual(unknown.verifiedIncrement, 0)
        XCTAssertEqual(unknown.committedIncrement, 0)
        XCTAssertNil(unknown.errorItem)
    }

    func testReceiptEventParserDoesNotIncrementForUnknownCommitStatus() {
        var parser = ReceiptEventParser()
        let update = parser.parse(line: "{\"event_type\":\"FILE_COMMITTED\",\"phase\":\"commit\",\"data\":{\"executed\":true,\"status\":\"mystery_status\",\"extra\":1}}")

        XCTAssertEqual(update.phase, .commit)
        XCTAssertEqual(update.committedIncrement, 0)
        XCTAssertNil(update.errorItem)
    }
}
