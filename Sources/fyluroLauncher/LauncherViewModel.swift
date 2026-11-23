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
    @Published var runState: LauncherRunState = .idle
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
    @Published var finalizedSidecarCount = 0
    @Published var finalizedConflictsRenamedCount = 0
    @Published var finalizedTotalDurationMs: Int?
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
    @Published var destinationSpaceState: LauncherDestinationSpaceState = .unchecked
    @Published var filmModeState: LauncherFilmModeState = .disabled
    @Published var throughputTracker = LauncherThroughputTracker()
    @Published var showThroughputGraph: Bool = UserDefaults.standard.bool(forKey: LauncherViewModel.showThroughputGraphDefaultsKey) {
        didSet {
            UserDefaults.standard.set(showThroughputGraph, forKey: Self.showThroughputGraphDefaultsKey)
        }
    }

    static let showThroughputGraphDefaultsKey = "fyluro.launcher.throughputGraph.visible"

    var filmModeEnabled: Bool {
        filmModeState.isEnabled
    }

    var filmModeConfiguration: FilmModeOverride? {
        filmModeState.configuration
    }

    var uiState: LauncherUIState {
        get { runState.uiState }
        set {
            switch newValue {
            case .idle:
                runState = .idle
            case .ready:
                runState = .ready
            case .running:
                if case .running = runState { break }
                runState = .running(stopRequested: false)
            case .success:
                if case .succeeded = runState { break }
                runState = .succeeded(idempotentRerun: false)
            case .failure:
                if case .failed = runState { break }
                runState = .failed(stoppedByUser: false)
            }
        }
    }

    var wasStoppedByUser: Bool {
        if case .failed(stoppedByUser: true) = runState {
            return true
        }
        return false
    }

    var idempotentRerunDetected: Bool {
        if case .succeeded(idempotentRerun: true) = runState {
            return true
        }
        return false
    }

    var destinationSpaceCheck: DestinationSpaceChecker.CheckOutcome? {
        destinationSpaceState.checkOutcome
    }

    var destinationSpaceOverrideAccepted: Bool {
        destinationSpaceState.isOverrideAccepted
    }

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
    let ingestRunnerFactory: (IngestRequest, (any SourceScanMetadataCaching)?) -> IngestRunHandle
    var activeRun: IngestRunHandle?
    var ingestTask: Task<Void, Never>?
    @Published var pdfSummaryPath = ""
    var parsedResult: LauncherRunResult?
    var parsedIdempotentRerun = false
    var latestCorePhase: LauncherPhase = .idle
    var receiptPreviewLines: [String] = []
    var seenErrorEventIndexes: Set<Int> = []
    var progressCounters = LauncherProgressCounters()
    var bytesToCopy: Int64 = 0
    var copiedBytesByPath: [String: Int64] = [:]
    var verifiedBytesByPath: [String: Int64] = [:]
    var totalCopiedBytes: Int64 = 0
    var totalVerifiedBytes: Int64 = 0
    var throughputTickTask: Task<Void, Never>?
    var runStartedAt: Date?
    var lastProgressEventAt: Date?
    var sawFinishedEvent = false
    var sourceScanTask: Task<Void, Never>?
    var destinationSpaceCheckTask: Task<Void, Never>?
    var lastDestinationSpaceCheckedPath = ""
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

    func applyFilmMode(_ override: FilmModeOverride) {
        filmModeState = .enabled(override)
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

    func disableFilmMode() {
        filmModeState = .disabled
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
        throughputTickTask?.cancel()
        sourceScanTask?.cancel()
        destinationSpaceCheckTask?.cancel()
        for observer in workspaceObservers {
            workspaceNotificationCenter.removeObserver(observer)
        }
    }
}
