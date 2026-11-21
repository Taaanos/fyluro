import Foundation
import FyluroCore

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
    let destinationMediumType: DestinationMediumType
    let detectTimeoutSeconds: Int
    let pickSource: Bool
    let pickDestination: Bool
    let pathSchemeString: String
    let filmModeOverride: FilmModeOverride?
    let useCameraCatalog: Bool
    let hardwareVerification: Bool

    init(request: IngestRequest, destinationMediumType: DestinationMediumType = .unknown) {
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
        self.destinationMediumType = destinationMediumType
        detectTimeoutSeconds = request.detectTimeoutSeconds
        pickSource = request.pickSource
        pickDestination = request.pickDestination
        pathSchemeString = request.pathScheme.receiptPathSchemeString
        filmModeOverride = request.filmModeOverride
        useCameraCatalog = request.useCameraCatalog
        hardwareVerification = request.hardwareVerification
    }
}

enum IngestRunOutcome {
    case completed
    case aborted(phase: IngestPhase, reason: String)

    var statusString: String {
        switch self {
        case .completed:
            return "completed"
        case .aborted:
            return "aborted"
        }
    }

    var isCompleted: Bool {
        if case .completed = self {
            return true
        }
        return false
    }

    var failurePhase: IngestPhase? {
        if case let .aborted(phase, _) = self {
            return phase
        }
        return nil
    }

    var failureReason: String? {
        if case let .aborted(_, reason) = self {
            return reason
        }
        return nil
    }
}

struct IngestSessionState {
    var outcome: IngestRunOutcome = .completed
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
