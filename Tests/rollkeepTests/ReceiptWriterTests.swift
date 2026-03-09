import Foundation
import XCTest
@testable import rollkeep

final class ReceiptWriterTests: XCTestCase {
    private var tempRoot: URL!

    override func setUpWithError() throws {
        let unique = "rollkeep-receipt-tests-\(UUID().uuidString.lowercased())"
        tempRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(unique, isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
    }

    func testAppendWritesNdjsonWithRequiredEnvelopeFields() throws {
        let writer = try ReceiptWriter(destRoot: tempRoot, sessionID: "session-123", fileManager: .default)

        try writer.append(eventType: .summary, phase: .finalize, data: [
            "status": "completed",
            "verified_ok": false,
        ])

        let events = try readEvents(atPath: writer.sink.path)
        XCTAssertEqual(events.count, 1)

        let event = try XCTUnwrap(events.first)
        XCTAssertEqual(event["session_id"] as? String, "session-123")
        XCTAssertEqual(event["event_type"] as? String, ReceiptEventType.summary.rawValue)
        XCTAssertEqual(event["phase"] as? String, IngestPhase.finalize.rawValue)
        XCTAssertEqual(event["event_index"] as? Int, 1)
        XCTAssertNotNil(event["timestamp"] as? String)

        let data = try XCTUnwrap(event["data"] as? [String: Any])
        XCTAssertEqual(data["status"] as? String, "completed")
    }

    func testInitFallsBackToLocalReceiptWhenDestinationPathIsNotWritableDirectory() throws {
        let blockedRoot = tempRoot.appendingPathComponent("blocked", isDirectory: false)
        FileManager.default.createFile(atPath: blockedRoot.path, contents: Data("x".utf8))

        let writer = try ReceiptWriter(destRoot: blockedRoot, sessionID: "session-fallback", fileManager: .default)

        XCTAssertEqual(writer.sink.kind, .localFallback)
        XCTAssertTrue(writer.sink.path.contains("/rollkeep/_ingest_receipts/session-fallback.ndjson"))
    }

    func testResumeHookTracksLastEventAndReceiptPath() throws {
        let writer = try ReceiptWriter(destRoot: tempRoot, sessionID: "session-resume", fileManager: .default)

        try writer.append(eventType: .sessionStarted, phase: .scan, data: ["source": "/source"])
        try writer.append(eventType: .sessionFinished, phase: .finalize, data: ["status": "completed"])

        let hook = writer.resumeHook()
        XCTAssertEqual(hook["session_id"] as? String, "session-resume")
        XCTAssertEqual(hook["last_event_index"] as? Int, 2)

        let receiptPaths = try XCTUnwrap(hook["receipt_paths"] as? [[String: Any]])
        XCTAssertEqual(receiptPaths.count, 1)
        XCTAssertEqual(receiptPaths.first?["kind"] as? String, ReceiptSink.Kind.destination.rawValue)
        XCTAssertEqual(hook["active_receipt_path"] as? String, writer.sink.path)
    }

    private func readEvents(atPath path: String) throws -> [[String: Any]] {
        let fileData = try Data(contentsOf: URL(fileURLWithPath: path, isDirectory: false))
        let text = String(decoding: fileData, as: UTF8.self)

        let lines = text
            .split(whereSeparator: \.isNewline)
            .map(String.init)

        return try lines.map { line in
            let data = Data(line.utf8)
            let object = try JSONSerialization.jsonObject(with: data)
            guard let payload = object as? [String: Any] else {
                XCTFail("Expected receipt event dictionary")
                return [:]
            }
            return payload
        }
    }
}
