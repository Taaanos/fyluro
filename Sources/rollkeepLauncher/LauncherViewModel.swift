import Foundation
import RollKeepCore
import RollKeepEngine
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
    @Published var scannedAudioCount = 0
    @Published var scannedTotalBytes: Int64 = 0
    @Published var scannedFilesCheckedCount = 0
    @Published var scannedCheckedBytes: Int64 = 0
    @Published var receiptErrors: [ReceiptErrorItem] = []
    @Published var touchedPaths: [String] = []
    @Published var createdDirectories: [String] = []
    @Published var sourceScanState: LauncherSourceScanState = .idle
    @Published var wasStoppedByUser = false
    @Published var filmModeEnabled = false
    @Published var filmModeConfiguration: FilmModeOverride?

    static let byteCountFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        formatter.countStyle = .file
        formatter.includesUnit = true
        formatter.includesCount = true
        formatter.isAdaptive = true
        return formatter
    }()

    static let captureDateRangeDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMMd")
        return formatter
    }()

    static let captureDateRangeDayYearFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMMdyyyy")
        return formatter
    }()

    let sourceDefaulting: LauncherSourceDefaulting
    let destinationDefaulting: LauncherDestinationDefaulting
    let destinationRemembering: LauncherDestinationRemembering
    let pathSchemeSettingsStore: LauncherPathSchemeSettingsStore
    let filmModeRemembering: LauncherFilmModeRemembering
    let sourceScanner: any LauncherSourceScanning
    let finderOpening: any LauncherFinderOpening
    /// Starts an in-process ingest. Injectable so tests can supply fault
    /// injection or a stub engine without spawning anything.
    let ingestRunnerFactory: (IngestRequest, (any SourceScanMetadataCaching)?) -> IngestRunHandle
    var activeRun: IngestRunHandle?
    var ingestTask: Task<Void, Never>?
    @Published var pdfSummaryPath = ""
    var parsedResult: LauncherRunResult?
    var latestCorePhase: LauncherPhase = .idle
    var receiptPreviewLines: [String] = []
    var seenErrorEventIndexes: Set<Int> = []
    var progressCounters = LauncherProgressCounters()
    var bytesToCopy: Int64 = 0
    var copiedBytesByPath: [String: Int64] = [:]
    var runStartedAt: Date?
    var lastProgressEventAt: Date?
    var sawFinishedEvent = false
    var sourceScanTask: Task<Void, Never>?
    var stopRequestedByUser = false
    var hasPreparedLaunchDefaults = false
    var lastPreviewSummary: LauncherSourceScopeSummary?
    var previewMetadataCache: (any SourceScanMetadataCaching)?

    init(
        sourceDefaulting: LauncherSourceDefaulting = LauncherSourceAutoPicker(),
        destinationRemembering: LauncherDestinationRemembering = LauncherDestinationMemory(),
        destinationDefaulting: LauncherDestinationDefaulting? = nil,
        pathSchemeSettingsStore: LauncherPathSchemeSettingsStore? = nil,
        filmModeRemembering: LauncherFilmModeRemembering = LauncherFilmModeMemory(),
        sourceScanner: any LauncherSourceScanning = LauncherSharedSourceScanner(),
        finderOpening: any LauncherFinderOpening = LauncherFinderWorkspace(),
        ingestRunnerFactory: @escaping (IngestRequest, (any SourceScanMetadataCaching)?) -> IngestRunHandle = { request, metadataCache in
            IngestSession.begin(request: request, previewMetadataCache: metadataCache)
        }
    ) {
        self.sourceDefaulting = sourceDefaulting
        self.destinationRemembering = destinationRemembering
        self.destinationDefaulting = destinationDefaulting ?? LauncherDestinationAutoPicker(memory: destinationRemembering)
        self.pathSchemeSettingsStore = pathSchemeSettingsStore ?? LauncherPathSchemeSettingsStore()
        self.filmModeRemembering = filmModeRemembering
        self.sourceScanner = sourceScanner
        self.finderOpening = finderOpening
        self.ingestRunnerFactory = ingestRunnerFactory
    }

    /// Turns Film Mode on for this run with the given override and remembers
    /// it (as the most-recently-used combo) for next time.
    func applyFilmMode(_ override: FilmModeOverride) {
        filmModeConfiguration = override
        filmModeEnabled = true
        filmModeRemembering.recordApplied(camera: override.camera, filmStock: override.filmStock, iso: override.iso)
    }

    /// The toggle is strictly binary: turning it off always clears the
    /// configured override, with no separate re-edit affordance.
    func disableFilmMode() {
        filmModeEnabled = false
        filmModeConfiguration = nil
    }

    deinit {
        ingestTask?.cancel()
        sourceScanTask?.cancel()
    }
}
