import Foundation
import FyluroCore

/// Fully-resolved inputs for a single ingest session. Path/volume resolution and
/// argument parsing happen before this is built (in the CLI or the app); the
/// engine takes concrete source/destination URLs and a snapshotted path scheme.
///
/// The invocation-echo fields (`jsonSummaryRequested`, `detectTimeoutSeconds`,
/// `pickSource`, `pickDestination`) do not affect ingest behavior; they are
/// recorded verbatim in the `SESSION_STARTED` receipt event and the
/// `command_started` log to preserve the existing on-disk/stdout contract.
public struct IngestRequest: Sendable {
    public var sessionID: String
    public var sourceURL: URL
    public var destinationURL: URL
    public var sourceResolution: String
    public var destinationResolution: String
    public var pathScheme: ImportPathScheme
    public var dryRun: Bool
    public var writePDF: Bool
    public var maxParallelCopies: Int
    public var jsonSummaryRequested: Bool
    public var detectTimeoutSeconds: Int
    public var pickSource: Bool
    public var pickDestination: Bool
    public var filmModeOverride: FilmModeOverride?
    /// `false` makes the run ignore the user's camera catalog (ROL-6 Section 6). The app sets it
    /// from the "Use camera labels" setting. It is fixed at run start (I-10).
    public var useCameraCatalog: Bool
    /// `true` flushes each copied staging file to physical storage (`F_FULLFSYNC` on Darwin,
    /// falling back to `fsync`) and disables OS page caching (`F_NOCACHE`) on the read-back
    /// verification descriptor (ROL-6 Sections 3 and 8, ADR 0005). Fixed at run start (I-10).
    public var hardwareVerification: Bool

    public init(
        sessionID: String = UUID().uuidString.lowercased(),
        sourceURL: URL,
        destinationURL: URL,
        sourceResolution: String,
        destinationResolution: String,
        pathScheme: ImportPathScheme,
        dryRun: Bool,
        writePDF: Bool,
        maxParallelCopies: Int = 1,
        jsonSummaryRequested: Bool,
        detectTimeoutSeconds: Int,
        pickSource: Bool,
        pickDestination: Bool,
        filmModeOverride: FilmModeOverride? = nil,
        useCameraCatalog: Bool = true,
        hardwareVerification: Bool = true
    ) {
        self.sessionID = sessionID
        self.sourceURL = sourceURL
        self.destinationURL = destinationURL
        self.sourceResolution = sourceResolution
        self.destinationResolution = destinationResolution
        self.pathScheme = pathScheme
        self.dryRun = dryRun
        self.writePDF = writePDF
        self.maxParallelCopies = maxParallelCopies
        self.jsonSummaryRequested = jsonSummaryRequested
        self.detectTimeoutSeconds = detectTimeoutSeconds
        self.pickSource = pickSource
        self.pickDestination = pickDestination
        self.filmModeOverride = filmModeOverride
        self.useCameraCatalog = useCameraCatalog
        self.hardwareVerification = hardwareVerification
    }

    public var stagingSessionPath: String {
        destinationURL
            .appendingPathComponent("_ingest_staging", isDirectory: true)
            .appendingPathComponent(sessionID, isDirectory: true)
            .path
    }
}
