import Foundation
import RollKeepCore

/// Thread-safe boolean flag used to request cooperative cancellation.
final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    func cancel() {
        lock.lock(); defer { lock.unlock() }
        value = true
    }
}

/// Throttles per-byte copy progress so the event stream is not flooded. Emits
/// when the final byte count for a file is reached, or at most every ~100ms /
/// per 8 MiB advanced. Safe to call from parallel copy threads.
final class CopyProgressThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private var lastEmitAt = Date.distantPast
    private var lastBytesByPath: [String: Int64] = [:]

    private let minInterval: TimeInterval = 0.1
    private let minBytes: Int64 = 8 * 1_048_576

    /// Returns true if a progress event for this state should be emitted.
    func shouldEmit(path: String, bytesCopied: Int64, expectedBytes: Int64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if bytesCopied >= expectedBytes {
            lastBytesByPath[path] = bytesCopied
            lastEmitAt = Date()
            return true
        }
        let now = Date()
        let last = lastBytesByPath[path] ?? 0
        if now.timeIntervalSince(lastEmitAt) >= minInterval || bytesCopied - last >= minBytes {
            lastBytesByPath[path] = bytesCopied
            lastEmitAt = now
            return true
        }
        return false
    }
}

/// Drives one full ingest: scan → plan → copy → verify → commit → finalize.
///
/// `run()` is a blocking, synchronous call (the copy/commit engines are
/// `OperationQueue`/lock based). Use `begin(...)` for the async, observable form
/// suitable for a SwiftUI view model. It throws only for startup failures that
/// occur before a receipt exists; pipeline failures are captured in the returned
/// `IngestSessionResult` with `finalStatus == "aborted"`.
public final class IngestSession: @unchecked Sendable {
    let request: IngestRequest
    let logger: any IngestLogging
    let faultInjection: IngestFaultInjection
    /// Metadata resolved by an earlier Launcher preview scan of the same
    /// source root, consulted by the scan phase to avoid re-resolving
    /// metadata for files it already knows. `nil` for the CLI and any other
    /// caller with no preceding preview pass.
    let previewMetadataCache: (any SourceScanMetadataCaching)?

    /// Observer invoked with each `IngestEvent`. Set before `run()`; may be
    /// called from background copy/commit threads (implementations must be
    /// thread-safe — `AsyncStream.Continuation.yield` is).
    var eventObserver: (@Sendable (IngestEvent) -> Void)?

    /// Acquires and releases the idle-sleep power assertion for `run()`.
    var idleSleepAssertionManager: any IdleSleepAssertionManaging = SystemIdleSleepAssertionManager()

    private let cancellation = CancellationFlag()

    public init(
        request: IngestRequest,
        logger: any IngestLogging,
        faultInjection: IngestFaultInjection = .fromEnvironment(),
        previewMetadataCache: (any SourceScanMetadataCaching)? = nil
    ) {
        self.request = request
        self.logger = logger
        self.faultInjection = faultInjection
        self.previewMetadataCache = previewMetadataCache
    }

    /// Requests cooperative cancellation. The run aborts at the next phase/file/
    /// chunk boundary; staging is retained and the receipt records the abort.
    public func cancel() {
        cancellation.cancel()
    }

    var isCancelled: Bool { cancellation.isCancelled }

    func emit(_ event: IngestEvent) {
        eventObserver?(event)
    }

    func throwIfCancelled(phase: IngestPhase) throws {
        if cancellation.isCancelled {
            throw IngestRuntimeError(phase: phase, message: "Ingest cancelled by user")
        }
    }

    public func run() throws -> IngestSessionResult {
        let context = IngestSessionContext(request: request)

        let receiptWriter = try ReceiptWriter(
            destRoot: context.destinationURL,
            sessionID: context.sessionID,
            injectedDestinationAppendFailureAtEventIndex: faultInjection.receiptFailDestinationAppendAtEventIndex
        )
        receiptWriter.onLineAppended = { [weak self] line in
            self?.emit(.receiptLineAppended(line: line))
        }

        let sleepAssertion = idleSleepAssertionManager.acquire(
            reason: "RollKeep ingest \(context.sessionID)",
            logger: logger
        )
        defer { sleepAssertion?.release() }

        emit(.sessionStarted(
            sessionID: context.sessionID,
            receiptPath: receiptWriter.sink.path,
            receiptSink: receiptWriter.sink.kind.rawValue
        ))

        let cameraLabeler = CameraLabeler.forRun(usingUserCatalog: context.useCameraCatalog)
        let preparationService = IngestPreparationService(
            sourceScanner: SourceScanner(
                forcedMissingCaptureDateRelativePaths: faultInjection.forceMissingCaptureDateRelativePaths,
                cameraLabeler: cameraLabeler
            ),
            cameraLabeler: cameraLabeler,
            destinationPathPlanner: DestinationPathPlanner(pathScheme: request.pathScheme)
        )

        let isoFormatter = ISO8601DateFormatter()
        var state = IngestSessionState()
        state.touchedPaths.addWrittenReceiptFile(receiptWriter.sink.path)

        try logCommandStartedAndWriteSessionStart(
            context: context,
            logger: logger,
            receiptWriter: receiptWriter
        )

        do {
            try executePipelinePhases(
                context: context,
                state: &state,
                preparationService: preparationService,
                isoFormatter: isoFormatter,
                logger: logger,
                receiptWriter: receiptWriter
            )
        } catch {
            handlePipelineFailure(
                context: context,
                state: &state,
                logger: logger,
                receiptWriter: receiptWriter,
                error: error
            )
        }

        let result = finalizeSession(
            context: context,
            state: &state,
            isoFormatter: isoFormatter,
            logger: logger,
            receiptWriter: receiptWriter
        )

        emit(.finished(result))
        return result
    }

    static func corruptStagedFileForVerifyMismatch(path: String) throws {
        let fileURL = URL(fileURLWithPath: path, isDirectory: false)
        let handle = try FileHandle(forUpdating: fileURL)
        defer { try? handle.close() }

        try handle.seek(toOffset: 0)
        let originalFirstByte = try handle.read(upToCount: 1) ?? Data([0x00])
        let baseline = originalFirstByte.first ?? 0x00
        let replacement = Data([baseline ^ 0xFF])

        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: replacement)
        try handle.synchronize()
    }
}

public extension IngestSession {
    /// Starts an ingest and returns a handle exposing an `AsyncStream` of events
    /// plus a completion task. `run()` executes on a dedicated `Thread` (it is
    /// blocking and would otherwise starve the Swift-concurrency cooperative
    /// pool). The event stream is terminated when the run finishes or throws.
    static func begin(
        request: IngestRequest,
        logger: (any IngestLogging)? = nil,
        faultInjection: IngestFaultInjection = .fromEnvironment(),
        previewMetadataCache: (any SourceScanMetadataCaching)? = nil
    ) -> IngestRunHandle {
        let session = IngestSession(
            request: request,
            logger: logger ?? NoopIngestLogger(),
            faultInjection: faultInjection,
            previewMetadataCache: previewMetadataCache
        )

        let (stream, continuation) = AsyncStream<IngestEvent>.makeStream(bufferingPolicy: .unbounded)
        session.eventObserver = { event in
            continuation.yield(event)
        }

        let completion = Task<IngestSessionResult, Error>.detached {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<IngestSessionResult, Error>) in
                let thread = Thread {
                    defer { continuation.finish() }
                    do {
                        cont.resume(returning: try session.run())
                    } catch {
                        cont.resume(throwing: error)
                    }
                }
                thread.stackSize = 4 << 20
                thread.name = "rollkeep.ingest"
                thread.start()
            }
        }

        return IngestRunHandle(events: stream, completion: completion, session: session)
    }
}
