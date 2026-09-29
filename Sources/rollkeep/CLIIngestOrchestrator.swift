import ArgumentParser
import Foundation
import RollKeepCore
import RollKeepEngine

extension RollkeepCLI {
    mutating func run() throws {
        let pathScheme = try resolvePathScheme()
        let logger = StructuredLogger(verbose: verbose)
        warnIfCameraCatalogIsUnreadable()

        let resolvedPaths = try VolumeResolver(
            explicitSourcePath: source,
            explicitDestinationPath: dest,
            detectTimeoutSeconds: detectTimeoutSeconds,
            forceSourcePicker: pickSource,
            forceDestinationPicker: pickDest,
            logger: logger
        ).resolve()

        let request = IngestRequest(
            sourceURL: resolvedPaths.sourceURL,
            destinationURL: resolvedPaths.destinationURL,
            sourceResolution: resolvedPaths.sourceResolution,
            destinationResolution: resolvedPaths.destinationResolution,
            pathScheme: pathScheme,
            dryRun: dryRun,
            writePDF: pdf,
            maxParallelCopies: maxParallelCopies,
            jsonSummaryRequested: json,
            detectTimeoutSeconds: detectTimeoutSeconds,
            pickSource: pickSource,
            pickDestination: pickDest
        )

        let result = try IngestSession(request: request, logger: logger).run()

        let exitCode = RollkeepExitCode.resolve(
            finalStatus: result.finalStatus,
            failurePhase: result.failurePhase
        )

        let finalSummaryRenderer = FinalSummaryRenderer()
        if json {
            print(finalSummaryRenderer.renderJSON(result, exitCode: exitCode.rawValue))
        } else {
            print(finalSummaryRenderer.renderHuman(result, exitCode: exitCode.rawValue))
        }

        if exitCode != .success {
            throw ExitCode(exitCode.rawValue)
        }
    }

    /// An unreadable catalog never aborts ingest; cameras just fall back to
    /// their raw model code (ROL-6 Section 6).
    private func warnIfCameraCatalogIsUnreadable() {
        let reader = CameraUserCatalogReader()
        guard case .malformed(let reason) = reader.load() else {
            return
        }

        let message = "warning: camera catalog \(reader.fileURL.path) is unreadable (\(reason)); cameras will use their raw model code as the label.\n"
        FileHandle.standardError.write(Data(message.utf8))
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
