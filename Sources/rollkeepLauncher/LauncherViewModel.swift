import Foundation
import RollKeepCore
import SwiftUI

@MainActor
final class LauncherViewModel: ObservableObject {
    @Published var sourcePath = "" {
        didSet {
            handlePathInputChanged(sourceChanged: true)
        }
    }

    @Published var destinationPath = "" {
        didSet {
            handlePathInputChanged(sourceChanged: false)
            rememberDestinationIfNeeded()
        }
    }

    @Published var outputText = ""
    @Published var receiptPreviewText = ""
    @Published var currentPhase: LauncherPhase = .idle
    @Published var uiState: LauncherUIState = .idle
    @Published var statusMessage = "Choose source and destination to begin."
    @Published var receiptPath = ""
    @Published var stagingPath = ""
    @Published var failureReason = ""
    @Published var executedCommand = ""
    @Published var scannedCandidateCount = 0
    @Published var plannedStageAndCommitCount = 0
    @Published var duplicateNotCopiedCount = 0
    @Published var copiedCount = 0
    @Published var verifiedCount = 0
    @Published var committedCount = 0
    @Published var currentFilePath = ""
    @Published var finalizedCommittedCount = 0
    @Published var finalizedDuplicateNotCopiedCount = 0
    @Published var finalizedTotalDurationMs: Int?
    @Published var idempotentRerunDetected = false
    @Published var scannedPhotoCount = 0
    @Published var scannedVideoCount = 0
    @Published var scannedTotalBytes: Int64 = 0
    @Published var scannedFilesCheckedCount = 0
    @Published var scannedCheckedBytes: Int64 = 0
    @Published var receiptErrors: [ReceiptErrorItem] = []
    @Published var touchedPaths: [String] = []
    @Published var createdDirectories: [String] = []
    @Published var sourceScanState: LauncherSourceScanState = .idle
    @Published var wasStoppedByUser = false

    static let byteCountFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        formatter.countStyle = .file
        formatter.includesUnit = true
        formatter.includesCount = true
        formatter.isAdaptive = true
        return formatter
    }()

    let sourceDefaulting: LauncherSourceDefaulting
    let destinationDefaulting: LauncherDestinationDefaulting
    let destinationRemembering: LauncherDestinationRemembering
    let pathSchemeSettingsStore: LauncherPathSchemeSettingsStore
    let sourceScanner: any LauncherSourceScanning
    let finderOpening: any LauncherFinderOpening
    let cliExecutableResolver: () -> URL?
    let ingestProcessEnvironmentProvider: () -> [String: String]
    var activeProcess: Process?
    var parser = CLIOutputParser()
    var receiptParser = ReceiptEventParser()
    var stdoutCarry = ""
    var stderrCarry = ""
    var receiptCarry = ""
    @Published var pdfSummaryPath = ""
    var parsedResult: LauncherRunResult?
    var latestCorePhase: LauncherPhase = .idle
    var receiptPollTimer: Timer?
    var monitoredReceiptPath = ""
    var receiptReadOffset: UInt64 = 0
    var receiptPreviewLines: [String] = []
    var seenErrorEventIndexes: Set<Int> = []
    var progressCounters = LauncherProgressCounters()
    var runStartedAt: Date?
    var lastProgressEventAt: Date?
    var sourceScanTask: Task<Void, Never>?
    var stopRequestedByUser = false
    var hasPreparedLaunchDefaults = false
    var lastPreviewSummary: LauncherSourceScopeSummary?

    init(
        sourceDefaulting: LauncherSourceDefaulting = LauncherSourceAutoPicker(),
        destinationRemembering: LauncherDestinationRemembering = LauncherDestinationMemory(),
        destinationDefaulting: LauncherDestinationDefaulting? = nil,
        pathSchemeSettingsStore: LauncherPathSchemeSettingsStore? = nil,
        sourceScanner: any LauncherSourceScanning = LauncherSharedSourceScanner(),
        finderOpening: any LauncherFinderOpening = LauncherFinderWorkspace(),
        cliExecutableResolver: @escaping () -> URL? = { RollkeepCLIExecutableLocator.resolve() },
        ingestProcessEnvironmentProvider: @escaping () -> [String: String] = { ProcessInfo.processInfo.environment }
    ) {
        self.sourceDefaulting = sourceDefaulting
        self.destinationRemembering = destinationRemembering
        self.destinationDefaulting = destinationDefaulting ?? LauncherDestinationAutoPicker(memory: destinationRemembering)
        self.pathSchemeSettingsStore = pathSchemeSettingsStore ?? LauncherPathSchemeSettingsStore()
        self.sourceScanner = sourceScanner
        self.finderOpening = finderOpening
        self.cliExecutableResolver = cliExecutableResolver
        self.ingestProcessEnvironmentProvider = ingestProcessEnvironmentProvider
    }

    deinit {
        receiptPollTimer?.invalidate()
        sourceScanTask?.cancel()
    }
}
