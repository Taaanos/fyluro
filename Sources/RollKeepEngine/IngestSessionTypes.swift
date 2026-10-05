import Foundation
import RollKeepCore

struct IngestSessionContext {
    let sessionID: String
    let sourceURL: URL
    let destinationURL: URL
    let sourceResolution: String
    let destinationResolution: String
    let stagingSessionPath: String
    let dryRun: Bool
    let pdf: Bool
    let json: Bool
    let maxParallelCopies: Int
    let detectTimeoutSeconds: Int
    let pickSource: Bool
    let pickDestination: Bool
    let pathSchemeString: String
    let filmModeOverride: FilmModeOverride?
    let useCameraCatalog: Bool

    init(request: IngestRequest) {
        sessionID = request.sessionID
        sourceURL = request.sourceURL
        destinationURL = request.destinationURL
        sourceResolution = request.sourceResolution
        destinationResolution = request.destinationResolution
        stagingSessionPath = request.stagingSessionPath
        dryRun = request.dryRun
        pdf = request.writePDF
        json = request.jsonSummaryRequested
        maxParallelCopies = request.maxParallelCopies
        detectTimeoutSeconds = request.detectTimeoutSeconds
        pickSource = request.pickSource
        pickDestination = request.pickDestination
        pathSchemeString = request.pathScheme.receiptPathSchemeString
        filmModeOverride = request.filmModeOverride
        useCameraCatalog = request.useCameraCatalog
    }
}

struct IngestSessionState {
    var finalStatus = "completed"
    var failurePhase = IngestPhase.finalize
    var failureReason: String?
    var scanSummary: ScanSummary?
    var destinationPlan: DestinationPathPlanner.Plan?
    var cardAssessment: CameraCardAssessment?
    var touchedPaths = ReceiptTouchedPaths()
    var outcomeTotals = ReceiptOutcomeTotals()
    var pdfSummaryPath: String?
    var commitStageCompleted = false
    var filmModeExifApplied = 0
    var filmModeExifSkipped = 0
    var phaseTimings = PhaseTimingTracker()
    var firstErrors: [String] = []
    var commitResultsBySourcePath: [String: StagingCommitEngine.FileResult] = [:]

    var scanPhaseStartedAt: Date?
    var planPhaseStartedAt: Date?
    var copyPhaseStartedAt: Date?
    var commitPhaseStartedAt: Date?

    mutating func rememberError(_ message: String) {
        guard firstErrors.count < 3 else {
            return
        }
        firstErrors.append(message)
    }
}

struct IngestScanPlanOutput {
    let preparation: IngestPreparation
    let summary: ScanSummary
    let plan: DestinationPathPlanner.Plan
    let copyJobs: [StagingCopyEngine.FileJob]
    let sourceDatesByPath: [String: (modificationDate: Date, creationDate: Date?)]
    let plannedBySourcePath: [String: DestinationPathPlanner.PlannedFile]
}
