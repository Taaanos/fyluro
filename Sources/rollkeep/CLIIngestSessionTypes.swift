import Foundation
import RollKeepCore

struct CLIIngestSessionContext {
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
}

struct CLIIngestSessionState {
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
    var phaseTimings = PhaseTimingTracker()
    var firstErrors: [String] = []

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

struct CLIIngestScanPlanOutput {
    let preparation: IngestPreparation
    let summary: ScanSummary
    let plan: DestinationPathPlanner.Plan
    let copyJobs: [StagingCopyEngine.FileJob]
    let sourceDatesByPath: [String: (modificationDate: Date, creationDate: Date?)]
    let plannedBySourcePath: [String: DestinationPathPlanner.PlannedFile]
}
