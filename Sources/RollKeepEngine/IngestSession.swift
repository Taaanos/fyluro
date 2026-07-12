import Foundation
import RollKeepCore

/// Drives one full ingest: scan → plan → copy → verify → commit → finalize.
///
/// `run()` is a blocking, synchronous call (the copy/commit engines are
/// `OperationQueue`/lock based). It throws only for startup failures that occur
/// before a receipt exists (for example, no writable receipt sink). Failures
/// during the pipeline are captured and reported in the returned
/// `IngestSessionResult` with `finalStatus == "aborted"`, mirroring the CLI's
/// existing behavior.
public final class IngestSession {
    let request: IngestRequest
    let logger: any IngestLogging

    public init(request: IngestRequest, logger: any IngestLogging) {
        self.request = request
        self.logger = logger
    }

    public func run() throws -> IngestSessionResult {
        let context = IngestSessionContext(request: request)

        let receiptWriter = try ReceiptWriter(destRoot: context.destinationURL, sessionID: context.sessionID)
        let forcedMissingCaptureDatePaths = IngestEnvironmentParsing.parseRelativePathSet(
            name: "ROLLKEEP_TEST_FORCE_MISSING_CAPTURE_DATE_RELATIVE_PATHS"
        )

        let preparationService = IngestPreparationService(
            sourceScanner: SourceScanner(
                forcedMissingCaptureDateRelativePaths: forcedMissingCaptureDatePaths
            ),
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

        return finalizeSession(
            context: context,
            state: &state,
            isoFormatter: isoFormatter,
            logger: logger,
            receiptWriter: receiptWriter
        )
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
