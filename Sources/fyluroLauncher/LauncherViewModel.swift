import AppKit
import Foundation
import FyluroCore
import FyluroEngine
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
            transferSettingsStore.updateDestinationPath(destinationPath)
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
    @Published var finalizedFilmModeExifSkippedCount = 0
    @Published var finalizedPhotoCount = 0
    @Published var finalizedVideoCount = 0
    @Published var finalizedAudioCount = 0
    @Published var finalizedConflictsRenamedCount = 0
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
    @Published var destinationSpaceCheck: DestinationSpaceChecker.CheckOutcome?
    @Published var destinationSpaceOverrideAccepted = false
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
    let transferSettingsStore: LauncherTransferSettingsStore
    let cameraLabelsPreference: any LauncherCameraLabelsPreferring
    let filmModeRemembering: LauncherFilmModeRemembering
    let sourceScanner: any LauncherSourceScanning
    let finderOpening: any LauncherFinderOpening
    let bookmarkStore: any LauncherSecurityScopedBookmarking
    private let workspaceNotificationCenter: NotificationCenter
    private var workspaceObservers: [NSObjectProtocol] = []
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
    var verifiedBytesByPath: [String: Int64] = [:]
    var runStartedAt: Date?
    var lastProgressEventAt: Date?
    var sawFinishedEvent = false
    var sourceScanTask: Task<Void, Never>?
    var destinationSpaceCheckTask: Task<Void, Never>?
    var stopRequestedByUser = false
    var hasPreparedLaunchDefaults = false
    var lastPreviewSummary: LauncherSourceScopeSummary?
    var previewMetadataCache: (any SourceScanMetadataCaching)?

    init(
        sourceDefaulting: LauncherSourceDefaulting = LauncherSourceAutoPicker(),
        destinationRemembering: LauncherDestinationRemembering = LauncherDestinationMemory(),
        destinationDefaulting: LauncherDestinationDefaulting? = nil,
        pathSchemeSettingsStore: LauncherPathSchemeSettingsStore? = nil,
        transferSettingsStore: LauncherTransferSettingsStore? = nil,
        filmModeRemembering: LauncherFilmModeRemembering = LauncherFilmModeMemory(),
        sourceScanner: any LauncherSourceScanning = LauncherSharedSourceScanner(),
        cameraLabelsPreference: any LauncherCameraLabelsPreferring = LauncherCameraLabelsPreference(),
        finderOpening: any LauncherFinderOpening = LauncherFinderWorkspace(),
        bookmarkStore: any LauncherSecurityScopedBookmarking = LauncherSecurityScopedBookmarkStore(),
        workspaceNotificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
        ingestRunnerFactory: @escaping (IngestRequest, (any SourceScanMetadataCaching)?) -> IngestRunHandle = { request, metadataCache in
            IngestSession.begin(request: request, previewMetadataCache: metadataCache)
        }
    ) {
        self.sourceDefaulting = sourceDefaulting
        self.destinationRemembering = destinationRemembering
        self.destinationDefaulting = destinationDefaulting ?? LauncherDestinationAutoPicker(memory: destinationRemembering)
        self.pathSchemeSettingsStore = pathSchemeSettingsStore ?? LauncherPathSchemeSettingsStore()
        self.transferSettingsStore = transferSettingsStore ?? LauncherTransferSettingsStore()
        self.filmModeRemembering = filmModeRemembering
        self.sourceScanner = sourceScanner
        self.cameraLabelsPreference = cameraLabelsPreference
        self.finderOpening = finderOpening
        self.bookmarkStore = bookmarkStore
        self.workspaceNotificationCenter = workspaceNotificationCenter
        self.ingestRunnerFactory = ingestRunnerFactory
        startObservingWorkspaceMountNotifications()
    }

    /// Turns Film Mode on for this run with the given override and remembers
    /// it (as the most-recently-used combo) for next time.
    func applyFilmMode(_ override: FilmModeOverride) {
        filmModeConfiguration = override
        filmModeEnabled = true
        filmModeRemembering.recordApplied(
            camera: override.camera,
            filmStock: override.filmStock,
            iso: override.iso,
            creator: override.creator,
            copyright: override.copyright,
            lens: override.lens,
            scannerSetup: override.scannerSetup
        )
    }

    /// Turns Film Mode off and clears the configured override. Only the switch
    /// calls this. The Edit… sheet changes the override with `applyFilmMode`,
    /// and cancelling that sheet leaves the saved override as it is.
    func disableFilmMode() {
        filmModeEnabled = false
        filmModeConfiguration = nil
    }

    private func startObservingWorkspaceMountNotifications() {
        let mountNames: [Notification.Name] = [
            NSWorkspace.didMountNotification,
            NSWorkspace.didUnmountNotification,
        ]
        for name in mountNames {
            let token = workspaceNotificationCenter.addObserver(
                forName: name,
                object: nil,
                queue: nil
            ) { [weak self] notification in
                if Thread.isMainThread {
                    MainActor.assumeIsolated {
                        self?.handleWorkspaceMountNotification(notification)
                    }
                } else {
                    Task { @MainActor [weak self] in
                        self?.handleWorkspaceMountNotification(notification)
                    }
                }
            }
            workspaceObservers.append(token)
        }
    }

    deinit {
        ingestTask?.cancel()
        sourceScanTask?.cancel()
        destinationSpaceCheckTask?.cancel()
        for observer in workspaceObservers {
            workspaceNotificationCenter.removeObserver(observer)
        }
    }
}
