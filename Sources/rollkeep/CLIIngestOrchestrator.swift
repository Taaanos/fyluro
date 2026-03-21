import ArgumentParser
import Foundation
import RollKeepCore

extension RollkeepCLI {
    mutating func run() throws {
        let pathScheme = try resolvePathScheme()
        let logger = StructuredLogger(verbose: verbose)

        let resolvedPaths = try VolumeResolver(
            explicitSourcePath: source,
            explicitDestinationPath: dest,
            detectTimeoutSeconds: detectTimeoutSeconds,
            forceSourcePicker: pickSource,
            forceDestinationPicker: pickDest,
            logger: logger
        ).resolve()

        let sessionID = UUID().uuidString.lowercased()
        let sourceURL = resolvedPaths.sourceURL
        let destinationURL = resolvedPaths.destinationURL
        let context = CLIIngestSessionContext(
            sessionID: sessionID,
            sourceURL: sourceURL,
            destinationURL: destinationURL,
            sourceResolution: resolvedPaths.sourceResolution,
            destinationResolution: resolvedPaths.destinationResolution,
            stagingSessionPath: destinationURL
                .appendingPathComponent("_ingest_staging", isDirectory: true)
                .appendingPathComponent(sessionID, isDirectory: true)
                .path,
            dryRun: dryRun,
            pdf: pdf,
            json: json,
            maxParallelCopies: maxParallelCopies,
            detectTimeoutSeconds: detectTimeoutSeconds,
            pickSource: pickSource,
            pickDestination: pickDest,
            pathSchemeString: pathScheme.receiptPathSchemeString
        )

        let receiptWriter = try ReceiptWriter(destRoot: context.destinationURL, sessionID: context.sessionID)
        let forcedMissingCaptureDatePaths = CLIIngestEnvironmentParsing.parseRelativePathSet(
            name: "ROLLKEEP_TEST_FORCE_MISSING_CAPTURE_DATE_RELATIVE_PATHS"
        )

        let preparationService = IngestPreparationService(
            sourceScanner: SourceScanner(
                forcedMissingCaptureDateRelativePaths: forcedMissingCaptureDatePaths
            ),
            destinationPathPlanner: DestinationPathPlanner(pathScheme: pathScheme)
        )

        let isoFormatter = ISO8601DateFormatter()
        var state = CLIIngestSessionState()
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

        let finalSummaryPayload = finalizeSession(
            context: context,
            state: &state,
            isoFormatter: isoFormatter,
            logger: logger,
            receiptWriter: receiptWriter
        )

        let finalSummaryRenderer = FinalSummaryRenderer()
        if context.json {
            print(finalSummaryRenderer.renderJSON(finalSummaryPayload))
        } else {
            print(finalSummaryRenderer.renderHuman(finalSummaryPayload))
        }

        if finalSummaryPayload.exitCode != RollkeepExitCode.success.rawValue {
            throw ExitCode(finalSummaryPayload.exitCode)
        }
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

    private func resolvePathScheme() throws -> ImportPathScheme {
        let chronologicalLayout: PathChronologicalLayout
        if let pathChronological {
            guard let parsed = PathChronologicalLayout.parseCLIValue(pathChronological) else {
                throw ValidationError("--path-chronological must be one of: YYYY/YYYYMM, YYYY/MM")
            }
            chronologicalLayout = parsed
        } else {
            chronologicalLayout = .yearYearMonthCompact
        }

        return ImportPathScheme(
            chronologicalLayout: chronologicalLayout,
            includeCameraFolder: !pathNoCamera,
            splitPhotoCompression: pathSplitRaw
        )
    }
}
