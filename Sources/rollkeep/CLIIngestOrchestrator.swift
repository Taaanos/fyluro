import ArgumentParser
import Foundation
import RollKeepCore
import RollKeepEngine
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

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

        let session = IngestSession(request: request, logger: logger)
        let signalCoordinator = CLISignalCoordinator(
            onFirstSignal: { sig in
                let name = CLISignalCoordinator.signalName(sig)
                let message = "Received \(name); cancelling ingest at next safe boundary...\n"
                FileHandle.standardError.write(Data(message.utf8))
                session.cancel()
            },
            onSecondSignal: { sig in
                let name = CLISignalCoordinator.signalName(sig)
                let message = "Received second signal (\(name)); exiting immediately.\n"
                FileHandle.standardError.write(Data(message.utf8))
                _exit(128 + sig)
            }
        )
        let signalMonitor = CLISignalMonitor()
        signalMonitor.start { sig in
            signalCoordinator.handleSignal(sig)
        }
        defer {
            signalMonitor.stop()
        }

        let result = try session.run()

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
