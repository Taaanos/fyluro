import Foundation
import FyluroCore

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

final class CopyProgressThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private var lastEmitAt = Date.distantPast
    private var lastBytesByPath: [String: Int64] = [:]

    private let minInterval: TimeInterval = 0.1
    private let minBytes: Int64 = 8 * 1_048_576

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

public enum IngestPreflightError: LocalizedError, Equatable, Sendable {
    case overlappingPaths(source: String, destination: String, relation: DirectoryPathRelation)

    public var errorDescription: String? {
        switch self {
        case .overlappingPaths(let source, let destination, let relation):
            return DirectoryPathPairAnalysis(
                sourcePath: source,
                destinationPath: destination,
                relation: relation
            ).overlapMessage
        }
    }
}

public final class IngestSession: @unchecked Sendable {
    let request: IngestRequest
    let logger: any IngestLogging
    let faultInjection: IngestFaultInjection
    let previewMetadataCache: (any SourceScanMetadataCaching)?
    let destinationMediumDetector: any DestinationMediumDetecting

    var eventObserver: (@Sendable (IngestEvent) -> Void)?

    var idleSleepAssertionManager: any IdleSleepAssertionManaging = SystemIdleSleepAssertionManager()

    private let cancellation = CancellationFlag()

    public init(
        request: IngestRequest,
        logger: any IngestLogging,
        faultInjection: IngestFaultInjection = .fromEnvironment(),
        previewMetadataCache: (any SourceScanMetadataCaching)? = nil,
        destinationMediumDetector: any DestinationMediumDetecting = IOKitDestinationMediumDetector()
    ) {
        self.request = request
        self.logger = logger
        self.faultInjection = faultInjection
        self.previewMetadataCache = previewMetadataCache
        self.destinationMediumDetector = destinationMediumDetector
    }

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
        let detectedMedium = destinationMediumDetector.detectMediumType(at: request.destinationURL)
        let context = IngestSessionContext(request: request, destinationMediumType: detectedMedium)

        let pairAnalysis = DirectoryPathOverlapValidator.analyze(
            sourcePath: context.sourceURL.path,
            destinationPath: context.destinationURL.path
        )
        guard pairAnalysis.isDisjoint else {
            throw IngestPreflightError.overlappingPaths(
                source: pairAnalysis.sourcePath,
                destination: pairAnalysis.destinationPath,
                relation: pairAnalysis.relation
            )
        }

        let receiptWriter = try ReceiptWriter(
            destRoot: context.destinationURL,
            sessionID: context.sessionID,
            injectedDestinationAppendFailureAtEventIndex: faultInjection.receiptFailDestinationAppendAtEventIndex
        )
        receiptWriter.onLineAppended = { [weak self] line in
            self?.emit(.receiptLineAppended(line: line))
        }

        let sleepAssertion = idleSleepAssertionManager.acquire(
            reason: "Fyluro ingest \(context.sessionID)",
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
    /// Runs blocking `run()` on a dedicated `Thread` so it does not starve the Swift-concurrency cooperative pool.
    static func begin(
        request: IngestRequest,
        logger: (any IngestLogging)? = nil,
        faultInjection: IngestFaultInjection = .fromEnvironment(),
        previewMetadataCache: (any SourceScanMetadataCaching)? = nil,
        destinationMediumDetector: any DestinationMediumDetecting = IOKitDestinationMediumDetector()
    ) -> IngestRunHandle {
        let session = IngestSession(
            request: request,
            logger: logger ?? NoopIngestLogger(),
            faultInjection: faultInjection,
            previewMetadataCache: previewMetadataCache,
            destinationMediumDetector: destinationMediumDetector
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
                thread.name = "fyluro.ingest"
                thread.start()
            }
        }

        return IngestRunHandle(events: stream, completion: completion, session: session)
    }
}
