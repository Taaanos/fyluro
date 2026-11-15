import Foundation
import XCTest
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
@testable import RollKeepEngine

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

    func testAppendFallsBackToLocalReceiptWhenDestinationAppendFailsMidSession() throws {
        let sessionID = "session-mid-fallback-\(UUID().uuidString.lowercased())"
        let destinationPath = tempRoot
            .appendingPathComponent("_ingest_receipts", isDirectory: true)
            .appendingPathComponent("\(sessionID).ndjson", isDirectory: false)
            .path

        let fallbackPath = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("rollkeep", isDirectory: true)
            .appendingPathComponent("_ingest_receipts", isDirectory: true)
            .appendingPathComponent("\(sessionID).ndjson", isDirectory: false)
            .path

        let destinationAppender = try XCTUnwrap(
            FlakyAppender(path: destinationPath, failOnAppendAttempt: 2, fileManager: .default)
        )
        let fallbackAppender = try XCTUnwrap(
            FlakyAppender(path: fallbackPath, failOnAppendAttempt: nil, fileManager: .default)
        )

        let writer = try ReceiptWriter(
            destRoot: tempRoot,
            sessionID: sessionID,
            fileManager: .default,
            appenderFactory: { path, _ in
                if path == destinationPath {
                    return destinationAppender
                }
                if path == fallbackPath {
                    return fallbackAppender
                }
                XCTFail("Unexpected appender path: \(path)")
                return fallbackAppender
            }
        )

        XCTAssertEqual(writer.sink.kind, .destination)
        try writer.append(eventType: .sessionStarted, phase: .scan, data: ["source": "/source"])
        try writer.append(eventType: .summary, phase: .finalize, data: ["status": "completed"])

        XCTAssertEqual(writer.sink.kind, .localFallback)
        XCTAssertEqual(writer.sinkTransitions.count, 1)
        XCTAssertEqual(writer.sinkTransitions.first?.reason, "destination_receipt_append_failed")

        let receiptPaths = writer.receiptPaths
        XCTAssertEqual(receiptPaths.count, 2)
        XCTAssertEqual(receiptPaths.first?.kind, .destination)
        XCTAssertEqual(receiptPaths.last?.kind, .localFallback)
        XCTAssertEqual(writer.sink.path, fallbackPath)

        let destinationEvents = try readEvents(atPath: destinationPath)
        XCTAssertEqual(destinationEvents.count, 1)
        XCTAssertEqual(destinationEvents.first?["event_index"] as? Int, 1)

        let fallbackEvents = try readEvents(atPath: fallbackPath)
        XCTAssertEqual(fallbackEvents.count, 1)
        XCTAssertEqual(fallbackEvents.first?["event_index"] as? Int, 2)
        XCTAssertEqual(fallbackEvents.first?["event_type"] as? String, ReceiptEventType.summary.rawValue)
    }

    func testAppendFallsBackWhenInjectedFailpointTriggersDestinationAppendFailure() throws {
        let sessionID = "session-injected-failpoint-\(UUID().uuidString.lowercased())"

        let writer = try ReceiptWriter(
            destRoot: tempRoot,
            sessionID: sessionID,
            fileManager: .default,
            injectedDestinationAppendFailureAtEventIndex: 2
        )
        XCTAssertEqual(writer.sink.kind, .destination)

        try writer.append(eventType: .sessionStarted, phase: .scan, data: ["source": "/source"])
        try writer.append(eventType: .summary, phase: .finalize, data: ["status": "completed"])

        XCTAssertEqual(writer.sink.kind, .localFallback)
        XCTAssertEqual(writer.sinkTransitions.count, 1)
        XCTAssertEqual(writer.sinkTransitions.first?.reason, "destination_receipt_append_failed")

        let receiptPaths = writer.receiptPaths
        XCTAssertEqual(receiptPaths.count, 2)
        XCTAssertEqual(receiptPaths.first?.kind, .destination)
        XCTAssertEqual(receiptPaths.last?.kind, .localFallback)
    }

    func testPeriodicDeferredAndFullSyncFlushPolicies() throws {
        let sessionID = "session-flush-policies-\(UUID().uuidString.lowercased())"
        let destinationPath = tempRoot
            .appendingPathComponent("_ingest_receipts", isDirectory: true)
            .appendingPathComponent("\(sessionID).ndjson", isDirectory: false)
            .path

        let appender = try FlakyAppender(path: destinationPath, failOnAppendAttempt: nil, fileManager: .default)
        var currentTime = Date(timeIntervalSince1970: 1_000)

        let writer = try ReceiptWriter(
            destRoot: tempRoot,
            sessionID: sessionID,
            fileManager: .default,
            periodicFlushInterval: 2.0,
            nowProvider: { currentTime },
            appenderFactory: { path, _ in
                XCTAssertEqual(path, destinationPath)
                return appender
            }
        )

        currentTime = Date(timeIntervalSince1970: 1_000.5)
        try writer.append(eventType: .scanProgress, phase: .scan, data: ["n": 1], flushPolicy: .periodic)
        currentTime = Date(timeIntervalSince1970: 1_001.5)
        try writer.append(eventType: .scanProgress, phase: .scan, data: ["n": 2], flushPolicy: .periodic)

        XCTAssertEqual(appender.appendCalls, 2)
        XCTAssertEqual(appender.flushCalls, 0)
        XCTAssertEqual(try readEvents(atPath: destinationPath).count, 2)

        currentTime = Date(timeIntervalSince1970: 1_002.0)
        try writer.append(eventType: .scanProgress, phase: .scan, data: ["n": 3], flushPolicy: .periodic)
        XCTAssertEqual(appender.flushCalls, 1)

        try writer.append(eventType: .fileCopied, phase: .copy, data: ["n": 4], flushPolicy: .deferred)
        try writer.append(eventType: .fileVerified, phase: .verify, data: ["n": 5], flushPolicy: .deferred)
        XCTAssertEqual(appender.flushCalls, 1)

        try writer.flush()
        XCTAssertEqual(appender.flushCalls, 2)

        // Calling flush again with no dirty lines is a no-op.
        try writer.flush()
        XCTAssertEqual(appender.flushCalls, 2)

        try writer.append(eventType: .sessionFinished, phase: .finalize, data: ["status": "completed"], flushPolicy: .fullSync)
        XCTAssertEqual(appender.flushCalls, 3)
        XCTAssertEqual(appender.fullSyncFlags, [false, false, true])
    }

    func testFlushFailureOnDestinationReplaysUnflushedLinesToLocalFallback() throws {
        let sessionID = "session-flush-fallback-\(UUID().uuidString.lowercased())"
        let destinationPath = tempRoot
            .appendingPathComponent("_ingest_receipts", isDirectory: true)
            .appendingPathComponent("\(sessionID).ndjson", isDirectory: false)
            .path
        let fallbackPath = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("rollkeep", isDirectory: true)
            .appendingPathComponent("_ingest_receipts", isDirectory: true)
            .appendingPathComponent("\(sessionID).ndjson", isDirectory: false)
            .path

        let destinationAppender = try FlakyAppender(
            path: destinationPath,
            failOnAppendAttempt: nil,
            failOnFlushAttempt: 2,
            fileManager: .default
        )
        let fallbackAppender = try FlakyAppender(
            path: fallbackPath,
            failOnAppendAttempt: nil,
            fileManager: .default
        )

        let writer = try ReceiptWriter(
            destRoot: tempRoot,
            sessionID: sessionID,
            fileManager: .default,
            appenderFactory: { path, _ in
                if path == destinationPath {
                    return destinationAppender
                }
                return fallbackAppender
            }
        )

        try writer.append(eventType: .sessionStarted, phase: .scan, data: ["source": "/source"], flushPolicy: .immediate)
        try writer.append(eventType: .fileCopied, phase: .copy, data: ["path": "a.jpg"], flushPolicy: .deferred)
        try writer.append(eventType: .fileVerified, phase: .verify, data: ["path": "a.jpg"], flushPolicy: .deferred)

        XCTAssertEqual(writer.sink.kind, .destination)

        try writer.flush()

        XCTAssertEqual(writer.sink.kind, .localFallback)
        XCTAssertEqual(writer.sinkTransitions.count, 1)

        let fallbackEvents = try readEvents(atPath: fallbackPath)
        XCTAssertEqual(fallbackEvents.count, 2)
        XCTAssertEqual(fallbackEvents[0]["event_index"] as? Int, 2)
        XCTAssertEqual(fallbackEvents[0]["event_type"] as? String, ReceiptEventType.fileCopied.rawValue)
        XCTAssertEqual(fallbackEvents[1]["event_index"] as? Int, 3)
        XCTAssertEqual(fallbackEvents[1]["event_type"] as? String, ReceiptEventType.fileVerified.rawValue)
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

private final class FlakyAppender: ReceiptAppending {
    private let inner: AnyReceiptAppender
    private let failOnAppendAttempt: Int?
    private let failOnFlushAttempt: Int?
    private(set) var appendCalls = 0
    private(set) var flushCalls = 0
    private(set) var fullSyncFlags: [Bool] = []

    init(
        path: String,
        failOnAppendAttempt: Int?,
        failOnFlushAttempt: Int? = nil,
        fileManager: FileManager
    ) throws {
        self.inner = try AnyReceiptAppender(path: path, fileManager: fileManager)
        self.failOnAppendAttempt = failOnAppendAttempt
        self.failOnFlushAttempt = failOnFlushAttempt
    }

    func append(_ lineData: Data) throws {
        appendCalls += 1
        if failOnAppendAttempt == appendCalls {
            throw ReceiptWriterError.appendFailed(path: "injected", errnoCode: EIO)
        }
        try inner.append(lineData)
    }

    func flush(fullSync: Bool) throws {
        flushCalls += 1
        fullSyncFlags.append(fullSync)
        if failOnFlushAttempt == flushCalls {
            throw ReceiptWriterError.appendFailed(path: "injected-flush", errnoCode: EIO)
        }
        try inner.flush(fullSync: fullSync)
    }
}

private final class AnyReceiptAppender: ReceiptAppending {
    private let fd: Int32
    private let path: String

    init(path: String, fileManager: FileManager) throws {
        self.path = path
        let fileURL = URL(fileURLWithPath: path, isDirectory: false)
        let dirURL = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: dirURL, withIntermediateDirectories: true)

        if !fileManager.fileExists(atPath: path),
           !fileManager.createFile(atPath: path, contents: nil) {
            throw ReceiptWriterError.openFailed(path: path, errnoCode: errno)
        }

        let descriptor = open(path, O_WRONLY | O_APPEND)
        if descriptor == -1 {
            throw ReceiptWriterError.openFailed(path: path, errnoCode: errno)
        }
        self.fd = descriptor
    }

    deinit {
        _ = close(fd)
    }

    func append(_ lineData: Data) throws {
        try lineData.withUnsafeBytes { rawBuffer in
            guard var pointer = rawBuffer.baseAddress else {
                return
            }

            var remainingBytes = rawBuffer.count
            while remainingBytes > 0 {
                let bytesWritten = write(fd, pointer, remainingBytes)
                if bytesWritten < 0 {
                    if errno == EINTR {
                        continue
                    }
                    throw ReceiptWriterError.appendFailed(path: path, errnoCode: errno)
                }

                remainingBytes -= bytesWritten
                pointer = pointer.advanced(by: bytesWritten)
            }
        }
    }

    func flush(fullSync: Bool) throws {
        #if canImport(Darwin)
        if fullSync {
            if fcntl(fd, F_FULLFSYNC) == 0 {
                return
            }
            if errno != ENOTSUP && errno != EINVAL && errno != ENOTTY {
                throw ReceiptWriterError.appendFailed(path: path, errnoCode: errno)
            }
        }
        #endif
        if fsync(fd) != 0 {
            throw ReceiptWriterError.appendFailed(path: path, errnoCode: errno)
        }
    }
}
