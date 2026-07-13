import Foundation
import RollKeepCore
import XCTest
@testable import RollKeepEngine

/// Covers the Phase 2 additions to IngestSession: the typed event observer,
/// cooperative cancellation (staging retained on abort), and struct-based
/// fault injection (no environment variables).
final class IngestSessionEventsTests: XCTestCase {
    private var tempRoot: URL!

    override func setUpWithError() throws {
        let unique = "rollkeep-session-events-\(UUID().uuidString.lowercased())"
        tempRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(unique, isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
    }

    // MARK: - Helpers

    private final class EventCollector: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var events: [IngestEvent] = []
        func record(_ event: IngestEvent) {
            lock.lock(); defer { lock.unlock() }
            events.append(event)
        }
        var snapshot: [IngestEvent] {
            lock.lock(); defer { lock.unlock() }
            return events
        }
    }

    private func makeSource(fileCount: Int, bytesEach: Int) throws -> URL {
        let source = tempRoot.appendingPathComponent("source", isDirectory: true)
        let dcim = source.appendingPathComponent("DCIM", isDirectory: true)
        try FileManager.default.createDirectory(at: dcim, withIntermediateDirectories: true)
        for index in 0..<fileCount {
            let name = String(format: "IMG_%04d.JPG", index)
            let data = Data((0..<bytesEach).map { UInt8(($0 &+ index) % 251) })
            FileManager.default.createFile(atPath: dcim.appendingPathComponent(name).path, contents: data)
        }
        return source
    }

    private func makeRequest(source: URL, dest: URL) -> IngestRequest {
        IngestRequest(
            sourceURL: source,
            destinationURL: dest,
            sourceResolution: "explicit",
            destinationResolution: "explicit",
            pathScheme: ImportPathScheme(
                chronologicalLayout: .yearYearMonthCompact,
                includeCameraFolder: true,
                splitPhotoCompression: false
            ),
            dryRun: false,
            writePDF: false,
            maxParallelCopies: 1,
            jsonSummaryRequested: false,
            detectTimeoutSeconds: 60,
            pickSource: false,
            pickDestination: false
        )
    }

    private func caseName(_ event: IngestEvent) -> String {
        switch event {
        case .sessionStarted: return "sessionStarted"
        case .phaseChanged: return "phaseChanged"
        case .scanProgress: return "scanProgress"
        case .scanCompleted: return "scanCompleted"
        case .planCompleted: return "planCompleted"
        case .fileCopyStarted: return "fileCopyStarted"
        case .fileCopyProgress: return "fileCopyProgress"
        case .fileVerified: return "fileVerified"
        case .fileCommitted: return "fileCommitted"
        case .duplicateSkipped: return "duplicateSkipped"
        case .receiptLineAppended: return "receiptLineAppended"
        case .errorRecorded: return "errorRecorded"
        case .finished: return "finished"
        }
    }

    // MARK: - Tests

    func testObserverReceivesLifecycleEventsInOrder() throws {
        let source = try makeSource(fileCount: 1, bytesEach: 4096)
        let dest = tempRoot.appendingPathComponent("dest", isDirectory: true)
        let collector = EventCollector()

        let session = IngestSession(request: makeRequest(source: source, dest: dest), logger: NoopIngestLogger(), faultInjection: .none)
        session.eventObserver = { collector.record($0) }
        let result = try session.run()

        XCTAssertEqual(result.finalStatus, "completed")
        XCTAssertEqual(result.counts.committed, 1)

        let names = collector.snapshot.map(caseName(_:))
        XCTAssertEqual(names.first, "sessionStarted")
        XCTAssertEqual(names.last, "finished")
        for required in ["scanCompleted", "planCompleted", "fileCopyStarted", "fileVerified", "fileCommitted"] {
            XCTAssertTrue(names.contains(required), "missing \(required) in \(names)")
        }
        // sessionStarted must precede the terminal finished.
        XCTAssertLessThan(names.firstIndex(of: "sessionStarted")!, names.lastIndex(of: "finished")!)

        // finished payload carries the result.
        guard case let .finished(finishedResult) = collector.snapshot.last else {
            return XCTFail("last event is not .finished")
        }
        XCTAssertEqual(finishedResult.counts.committed, 1)
    }

    func testReceiptLineAppendedMirrorsReceipt() throws {
        let source = try makeSource(fileCount: 1, bytesEach: 2048)
        let dest = tempRoot.appendingPathComponent("dest", isDirectory: true)
        let collector = EventCollector()

        let session = IngestSession(request: makeRequest(source: source, dest: dest), logger: NoopIngestLogger(), faultInjection: .none)
        session.eventObserver = { collector.record($0) }
        _ = try session.run()

        let lines = collector.snapshot.compactMap { event -> String? in
            if case let .receiptLineAppended(line) = event { return line }
            return nil
        }
        XCTAssertTrue(lines.contains { $0.contains("\"event_type\":\"SESSION_STARTED\"") })
        XCTAssertTrue(lines.contains { $0.contains("\"event_type\":\"SESSION_FINISHED\"") })
    }

    func testStructFaultInjectionFailsCopyWithoutEnvironment() throws {
        let source = try makeSource(fileCount: 2, bytesEach: 4096)
        let dest = tempRoot.appendingPathComponent("dest", isDirectory: true)

        let session = IngestSession(
            request: makeRequest(source: source, dest: dest),
            logger: NoopIngestLogger(),
            faultInjection: IngestFaultInjection(failCopyOnNthFile: 1, failCopyMessage: "boom-copy")
        )
        let result = try session.run()

        XCTAssertEqual(result.finalStatus, "aborted")
        XCTAssertEqual(result.failurePhase, .copy)
        XCTAssertEqual(result.counts.committed, 0)
    }

    func testUnreadableSourceFileEmitsErrorRecordedEvent() throws {
        let source = try makeSource(fileCount: 2, bytesEach: 4096)
        let unreadable = source.appendingPathComponent("DCIM/IMG_0000.JPG")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: unreadable.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: unreadable.path) }

        let dest = tempRoot.appendingPathComponent("dest", isDirectory: true)
        let collector = EventCollector()

        let session = IngestSession(request: makeRequest(source: source, dest: dest), logger: NoopIngestLogger(), faultInjection: .none)
        session.eventObserver = { collector.record($0) }
        let result = try session.run()

        XCTAssertEqual(result.finalStatus, "completed")
        XCTAssertEqual(result.counts.committed, 1)

        let scanErrors = collector.snapshot.compactMap { event -> (String, [String])? in
            if case let .errorRecorded(phase, message, paths) = event, phase == .scan { return (message, paths) }
            return nil
        }
        XCTAssertEqual(scanErrors.count, 1)
        XCTAssertEqual(scanErrors.first?.1.first?.hasSuffix("DCIM/IMG_0000.JPG"), true)
    }

    func testCancelBeforeRunAbortsAndStillFinishes() throws {
        let source = try makeSource(fileCount: 2, bytesEach: 4096)
        let dest = tempRoot.appendingPathComponent("dest", isDirectory: true)
        let collector = EventCollector()

        let session = IngestSession(request: makeRequest(source: source, dest: dest), logger: NoopIngestLogger(), faultInjection: .none)
        session.eventObserver = { collector.record($0) }
        session.cancel()
        let result = try session.run()

        XCTAssertEqual(result.finalStatus, "aborted")
        // A finished event is still emitted (receipt gets its abort tail).
        XCTAssertEqual(collector.snapshot.map(caseName(_:)).last, "finished")
    }

    func testCancelDuringCopyRetainsStaging() async throws {
        // Large file so the chunked copy loop observes the cancel flag mid-copy.
        let source = try makeSource(fileCount: 1, bytesEach: 24 * 1_048_576)
        let dest = tempRoot.appendingPathComponent("dest", isDirectory: true)

        let handle = IngestSession.begin(
            request: makeRequest(source: source, dest: dest),
            logger: nil,
            faultInjection: .none
        )

        var cancelled = false
        for await event in handle.events {
            if case .fileCopyProgress = event, !cancelled {
                cancelled = true
                handle.cancel()
            }
        }

        let result = try await handle.completion.value
        XCTAssertEqual(result.finalStatus, "aborted")

        // Staging session directory is retained on abort (cleanup only runs on completed).
        let stagingRoot = dest.appendingPathComponent("_ingest_staging", isDirectory: true)
        let sessions = (try? FileManager.default.contentsOfDirectory(atPath: stagingRoot.path)) ?? []
        XCTAssertFalse(sessions.isEmpty, "expected retained staging session after cancel")
    }
}
