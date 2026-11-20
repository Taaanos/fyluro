import Foundation
import XCTest
@testable import fyluro

final class FyluroCLIParallelCopiesTests: RuntimeFixtureTestCase {
    func testDefaultMaxParallelCopiesIsOneAndHelpMentionsRotationalMedia() throws {
        let parsed = try FyluroCLI.parse([])
        XCTAssertEqual(parsed.maxParallelCopies, 1)

        let help = FyluroCLI.helpMessage()
        XCTAssertTrue(help.contains("--max-parallel-copies"))
        XCTAssertTrue(help.contains("rotational"))
    }

    func testDryRunHonorsExplicitMaxParallelCopiesAndRecordsMediumTypeInReceipt() throws {
        let sourceRoot = tempRoot.appendingPathComponent("source", isDirectory: true)
        let destRoot = tempRoot.appendingPathComponent("dest", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destRoot, withIntermediateDirectories: true)
        _ = try createBinaryFile(path: "source/DCIM/100MEDIA/IMG_0001.JPG", bytes: 64)

        var command = try FyluroCLI.parseAsRoot([
            "--source", sourceRoot.path,
            "--dest", destRoot.path,
            "--dry-run",
            "--max-parallel-copies", "2",
        ])
        try command.run()

        let receiptsDir = destRoot.appendingPathComponent("_ingest_receipts", isDirectory: true)
        let receiptURL = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(
                at: receiptsDir,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ).first { $0.pathExtension == "ndjson" }
        )

        let lines = try String(contentsOf: receiptURL, encoding: .utf8).split(separator: "\n").map(String.init)
        let firstLine = try XCTUnwrap(lines.first)
        let event = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(firstLine.utf8)) as? [String: Any])
        XCTAssertEqual(event["event_type"] as? String, "SESSION_STARTED")
        let data = try XCTUnwrap(event["data"] as? [String: Any])
        XCTAssertEqual(data["max_parallel_copies"] as? Int, 2)
        XCTAssertNotNil(data["destination_medium_type"] as? String)
    }
}
