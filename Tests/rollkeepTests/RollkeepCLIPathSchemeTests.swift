import Foundation
import XCTest
@testable import rollkeep

final class RollkeepCLIPathSchemeTests: RuntimeFixtureTestCase {
    func testValidateRejectsRemovedConfigFlag() {
        XCTAssertThrowsError(try RollkeepCLI.parseAsRoot(["--config", "./rollkeep.yml"])) { error in
            XCTAssertTrue(error.localizedDescription.contains("ArgumentParser.CommandError"))
        }
    }

    func testValidateRejectsRemovedSkipVerifyFlag() {
        XCTAssertThrowsError(try RollkeepCLI.parseAsRoot(["--skip-verify"])) { error in
            XCTAssertTrue(error.localizedDescription.contains("ArgumentParser.CommandError"))
        }
    }

    func testValidateRejectsUnsupportedPathChronologicalValue() {
        XCTAssertThrowsError(try RollkeepCLI.parseAsRoot(["--path-chronological", "YYYY-DD"])) { error in
            XCTAssertTrue(error.localizedDescription.contains("ArgumentParser.CommandError"))
        }
    }

    func testDryRunReceiptIncludesPathSchemeForSessionPlanAndSummary() throws {
        let sourceRoot = tempRoot.appendingPathComponent("source", isDirectory: true)
        let destRoot = tempRoot.appendingPathComponent("dest", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destRoot, withIntermediateDirectories: true)
        _ = try createBinaryFile(path: "source/DCIM/100MEDIA/IMG_0001.JPG", bytes: 64)

        var command = try RollkeepCLI.parseAsRoot([
            "--source", sourceRoot.path,
            "--dest", destRoot.path,
            "--dry-run",
            "--path-chronological", "YYYY/MM",
            "--path-no-camera",
            "--path-split-raw",
        ])
        try command.run()

        let receiptURL = try XCTUnwrap(firstReceiptURL(in: destRoot))
        let events = try loadReceiptEvents(from: receiptURL)
        let expectedPathScheme = "YYYY/MM/<Photos|Videos>/<RAW|Non-RAW (Photos)>/<filename> ; _unsorted/<Photos|Videos>/<RAW|Non-RAW (Photos)>/<filename>"

        for eventType in ["SESSION_STARTED", "PLAN_COMPUTED", "SUMMARY"] {
            let eventData = try XCTUnwrap(data(forEventType: eventType, events: events))
            XCTAssertEqual(eventData["path_scheme"] as? String, expectedPathScheme)
            XCTAssertNil(eventData["path_chronological"])
            XCTAssertNil(eventData["path_no_camera"])
            XCTAssertNil(eventData["path_split_raw"])
        }
    }

    private func firstReceiptURL(in destinationRoot: URL) -> URL? {
        let receiptsDir = destinationRoot.appendingPathComponent("_ingest_receipts", isDirectory: true)
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: receiptsDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        return urls.first { $0.pathExtension == "ndjson" }
    }

    private func loadReceiptEvents(from url: URL) throws -> [[String: Any]] {
        let lines = try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n")
            .map(String.init)

        return try lines.map { line in
            let data = Data(line.utf8)
            let object = try JSONSerialization.jsonObject(with: data)
            guard let dictionary = object as? [String: Any] else {
                throw NSError(domain: "RollkeepCLIPathSchemeTests", code: 1)
            }
            return dictionary
        }
    }

    private func data(forEventType eventType: String, events: [[String: Any]]) -> [String: Any]? {
        for event in events {
            guard event["event_type"] as? String == eventType else {
                continue
            }
            return event["data"] as? [String: Any]
        }
        return nil
    }
}
