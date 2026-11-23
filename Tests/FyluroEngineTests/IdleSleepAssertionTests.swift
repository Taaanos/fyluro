import Foundation
import FyluroCore
import XCTest
@testable import FyluroEngine

final class IdleSleepAssertionTests: XCTestCase {
    private var tempRoot: URL!

    override func setUpWithError() throws {
        let unique = "fyluro-idle-sleep-\(UUID().uuidString.lowercased())"
        tempRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(unique, isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
    }

    private final class SpyToken: IdleSleepAssertionToken, @unchecked Sendable {
        private let onRelease: @Sendable () -> Void

        init(onRelease: @escaping @Sendable () -> Void) {
            self.onRelease = onRelease
        }

        func release() {
            onRelease()
        }
    }

    private final class SpyIdleSleepAssertionManager: IdleSleepAssertionManaging, @unchecked Sendable {
        private let lock = NSLock()
        private(set) var acquireCount = 0
        private(set) var releaseCount = 0
        private(set) var lastReason: String?

        func acquire(reason: String, logger: any IngestLogging) -> (any IdleSleepAssertionToken)? {
            lock.lock()
            acquireCount += 1
            lastReason = reason
            lock.unlock()

            return SpyToken { [weak self] in
                guard let self else { return }
                self.lock.lock()
                self.releaseCount += 1
                self.lock.unlock()
            }
        }
    }

    private struct FailingIdleSleepAssertionManager: IdleSleepAssertionManaging {
        func acquire(reason: String, logger: any IngestLogging) -> (any IdleSleepAssertionToken)? {
            nil
        }
    }

    private func makeSource(fileCount: Int) throws -> URL {
        let source = tempRoot.appendingPathComponent("source", isDirectory: true)
        let dcim = source.appendingPathComponent("DCIM", isDirectory: true)
        try FileManager.default.createDirectory(at: dcim, withIntermediateDirectories: true)
        for index in 0..<fileCount {
            let name = String(format: "IMG_%04d.JPG", index)
            let data = Data("sample-\(index)".utf8)
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

    func testSystemIdleSleepAssertionAcquiresAndReleasesOnMacOS() {
        let manager = SystemIdleSleepAssertionManager()
        let token = manager.acquire(reason: "Fyluro unit test", logger: NoopIngestLogger())
        XCTAssertNotNil(token)
        token?.release()
        token?.release()
    }

    func testSystemIdleSleepAssertionAcquiresAndEndsProcessActivityOnce() {
        final class Counter: @unchecked Sendable {
            let lock = NSLock()
            var activityOptions: ProcessInfo.ActivityOptions?
            var activityReason: String?
            var powerReleaseCount = 0
            var activityEndCount = 0
        }

        let counter = Counter()
        let manager = SystemIdleSleepAssertionManager(
            createPowerAssertion: { _ in (kIOReturnSuccess, 42) },
            releasePowerAssertion: { id in
                XCTAssertEqual(id, 42)
                counter.lock.lock()
                counter.powerReleaseCount += 1
                counter.lock.unlock()
            },
            beginProcessActivity: { options, reason in
                counter.lock.lock()
                counter.activityOptions = options
                counter.activityReason = reason
                counter.lock.unlock()
                return {
                    counter.lock.lock()
                    counter.activityEndCount += 1
                    counter.lock.unlock()
                }
            }
        )

        let token = manager.acquire(reason: "Fyluro ingest test-1", logger: NoopIngestLogger())
        XCTAssertNotNil(token)
        XCTAssertEqual(counter.activityOptions, .userInitiated)
        XCTAssertEqual(counter.activityReason, "Fyluro ingest test-1")

        token?.release()
        token?.release()

        XCTAssertEqual(counter.powerReleaseCount, 1)
        XCTAssertEqual(counter.activityEndCount, 1)
    }

    func testSystemIdleSleepAssertionKeepsProcessActivityWhenPowerAssertionFails() {
        final class Counter: @unchecked Sendable {
            let lock = NSLock()
            var powerReleaseCount = 0
            var activityEndCount = 0
        }

        let counter = Counter()
        let manager = SystemIdleSleepAssertionManager(
            createPowerAssertion: { _ in (kIOReturnError, 0) },
            releasePowerAssertion: { _ in
                counter.lock.lock()
                counter.powerReleaseCount += 1
                counter.lock.unlock()
            },
            beginProcessActivity: { _, _ in
                return {
                    counter.lock.lock()
                    counter.activityEndCount += 1
                    counter.lock.unlock()
                }
            }
        )

        let token = manager.acquire(reason: "Fyluro ingest fallback", logger: NoopIngestLogger())
        XCTAssertNotNil(token)
        token?.release()

        XCTAssertEqual(counter.powerReleaseCount, 0)
        XCTAssertEqual(counter.activityEndCount, 1)
    }

    func testIngestSessionAcquiresAndReleasesSleepAssertionOnSuccess() throws {
        let source = try makeSource(fileCount: 2)
        let dest = tempRoot.appendingPathComponent("dest", isDirectory: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)

        let spy = SpyIdleSleepAssertionManager()
        let session = IngestSession(
            request: makeRequest(source: source, dest: dest),
            logger: NoopIngestLogger(),
            faultInjection: .none
        )
        session.idleSleepAssertionManager = spy

        let result = try session.run()

        XCTAssertEqual(result.finalStatus, "completed")
        XCTAssertEqual(spy.acquireCount, 1)
        XCTAssertEqual(spy.releaseCount, 1)
        XCTAssertTrue(spy.lastReason?.hasPrefix("Fyluro ingest ") == true)
    }

    func testIngestSessionReleasesSleepAssertionOnPipelineFailure() throws {
        let missingSource = tempRoot.appendingPathComponent("missing-source", isDirectory: true)
        let dest = tempRoot.appendingPathComponent("dest", isDirectory: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)

        let spy = SpyIdleSleepAssertionManager()
        let session = IngestSession(
            request: makeRequest(source: missingSource, dest: dest),
            logger: NoopIngestLogger(),
            faultInjection: .none
        )
        session.idleSleepAssertionManager = spy

        let result = try session.run()

        XCTAssertEqual(result.finalStatus, "aborted")
        XCTAssertEqual(spy.acquireCount, 1)
        XCTAssertEqual(spy.releaseCount, 1)
    }

    func testIngestSessionCompletesWhenSleepAssertionAcquireReturnsNil() throws {
        let source = try makeSource(fileCount: 1)
        let dest = tempRoot.appendingPathComponent("dest", isDirectory: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)

        let session = IngestSession(
            request: makeRequest(source: source, dest: dest),
            logger: NoopIngestLogger(),
            faultInjection: .none
        )
        session.idleSleepAssertionManager = FailingIdleSleepAssertionManager()

        let result = try session.run()

        XCTAssertEqual(result.finalStatus, "completed")
    }
}
