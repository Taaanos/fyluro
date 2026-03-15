import AppKit
import Foundation
import RollKeepCore
import SwiftUI

enum LauncherUIState {
    case idle
    case ready
    case running
    case success
    case failure
}

private enum OutputStreamKind: String {
    case stdout = "stdout"
    case stderr = "stderr"
}

private enum LauncherSourceScanState: Equatable {
    case idle
    case scanning(LauncherSourceScopeSummary?)
    case ready(LauncherSourceScopeSummary)
    case failed(String)
}

protocol LauncherFinderOpening {
    func reveal(_ urls: [URL])
    @discardableResult
    func openDirectory(_ url: URL) -> Bool
}

struct LauncherFinderWorkspace: LauncherFinderOpening {
    func reveal(_ urls: [URL]) {
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    @discardableResult
    func openDirectory(_ url: URL) -> Bool {
        NSWorkspace.shared.open(url)
    }
}

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
    @Published private var sourceScanState: LauncherSourceScanState = .idle
    @Published private(set) var wasStoppedByUser = false

    private static let byteCountFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        formatter.countStyle = .file
        formatter.includesUnit = true
        formatter.includesCount = true
        formatter.isAdaptive = true
        return formatter
    }()

    private let sourceDefaulting: LauncherSourceDefaulting
    private let destinationDefaulting: LauncherDestinationDefaulting
    private let destinationRemembering: LauncherDestinationRemembering
    private let sourceScanner: any LauncherSourceScanning
    private let finderOpening: any LauncherFinderOpening
    private var activeProcess: Process?
    private var parser = CLIOutputParser()
    private var receiptParser = ReceiptEventParser()
    private var stdoutCarry = ""
    private var stderrCarry = ""
    private var receiptCarry = ""
    @Published var pdfSummaryPath = ""
    private var parsedResult: LauncherRunResult?
    private var latestCorePhase: LauncherPhase = .idle
    private var receiptPollTimer: Timer?
    private var monitoredReceiptPath = ""
    private var receiptReadOffset: UInt64 = 0
    private var receiptPreviewLines: [String] = []
    private var seenErrorEventIndexes: Set<Int> = []
    private var progressCounters = LauncherProgressCounters()
    private var runStartedAt: Date?
    private var lastProgressEventAt: Date?
    private var sourceScanTask: Task<Void, Never>?
    private var stopRequestedByUser = false
    private var hasPreparedLaunchDefaults = false
    private var lastPreviewSummary: LauncherSourceScopeSummary?

    init(
        sourceDefaulting: LauncherSourceDefaulting = LauncherSourceAutoPicker(),
        destinationRemembering: LauncherDestinationRemembering = LauncherDestinationMemory(),
        destinationDefaulting: LauncherDestinationDefaulting? = nil,
        sourceScanner: any LauncherSourceScanning = LauncherSharedSourceScanner(),
        finderOpening: any LauncherFinderOpening = LauncherFinderWorkspace()
    ) {
        self.sourceDefaulting = sourceDefaulting
        self.destinationRemembering = destinationRemembering
        self.destinationDefaulting = destinationDefaulting ?? LauncherDestinationAutoPicker(memory: destinationRemembering)
        self.sourceScanner = sourceScanner
        self.finderOpening = finderOpening
    }

    deinit {
        receiptPollTimer?.invalidate()
        sourceScanTask?.cancel()
    }

    var sourcePathValid: Bool {
        LauncherPathValidation.isValidSourcePath(sourcePath)
    }

    var destinationPathValid: Bool {
        LauncherPathValidation.isValidDestinationPath(destinationPath)
    }

    var sourceDestinationPairValid: Bool {
        LauncherPathValidation.isValidPathPair(sourcePath: sourcePath, destinationPath: destinationPath)
    }

    var canStart: Bool {
        !isRunning && sourcePathValid && destinationPathValid && sourceDestinationPairValid
    }

    var isImportReady: Bool {
        guard canStart else {
            return false
        }

        if case .ready = sourceScanState {
            return true
        }

        return false
    }

    var isRunning: Bool {
        uiState == .running
    }

    var canOpenReceipt: Bool {
        preferredReceiptOpenPath != nil
    }

    var canOpenStagingFolder: Bool {
        !stagingPath.isEmpty && FileManager.default.fileExists(atPath: stagingPath)
    }

    var canOpenDestination: Bool {
        destinationPathValid
    }

    var canOpenSource: Bool {
        sourcePathValid
    }

    var newFinalMediaDirectories: [String] {
        filterNewFinalMediaDirectories(createdDirectories, destinationPath: destinationPath)
    }

    var canOpenNewFinalMediaDirectories: Bool {
        !newFinalMediaDirectories.isEmpty
    }

    var statusColor: Color {
        switch uiState {
        case .success:
            return .green
        case .failure:
            return .red
        case .running:
            return .blue
        case .idle, .ready:
            return .primary
        }
    }

    var setupScopeSummaryText: String {
        switch sourceScanState {
        case .idle:
            return "Select a source to preview inventory."
        case .scanning(let summary):
            if let summary, summary.itemCount > 0 {
                return "Scanning source media... \(summary.itemCount) items found so far."
            }
            return "Scanning source media..."
        case .ready(let summary):
            if summary.itemCount == 0 {
                return "No media found."
            }
            return ""
        case .failed(let message):
            return message
        }
    }

    var isSourceScanning: Bool {
        if case .scanning(_) = sourceScanState {
            return true
        }
        return false
    }

    var setupInventory: LauncherSourceScopeSummary? {
        switch sourceScanState {
        case .scanning(let summary):
            return summary
        case .ready(let summary):
            return summary
        case .idle, .failed:
            return nil
        }
    }

    var setupInventoryCameraEntries: [LauncherSourceCameraSummary] {
        setupInventory?.cameraEntries ?? []
    }

    var setupInventorySizeText: String {
        formattedBytes(setupInventory?.totalBytes ?? 0)
    }

    var importTotalCount: Int? {
        var totals: [Int] = []

        if scannedCandidateCount > 0 {
            totals.append(scannedCandidateCount)
        }

        let planTotal = plannedStageAndCommitCount + duplicateNotCopiedCount
        if planTotal > 0 {
            totals.append(planTotal)
        }

        if case .ready(let summary) = sourceScanState, summary.itemCount > 0 {
            totals.append(summary.itemCount)
        }

        return totals.max()
    }

    var importingTitle: String {
        guard let total = importTotalCount, total > 0 else {
            return "Importing items..."
        }
        return "Importing \(total) items..."
    }

    var importingProgressText: String {
        if let total = importTotalCount, total > 0 {
            return "\(min(copiedCount, total)) of \(total) items copied"
        }

        if copiedCount > 0 {
            return "\(copiedCount) items copied"
        }

        return "Preparing items to copy"
    }

    var isImportScanPhase: Bool {
        latestCorePhase == .scan
    }

    var importingScanProgressText: String {
        let filesChecked = max(scannedFilesCheckedCount, scannedCandidateCount)
        let candidates = max(scannedCandidateCount, scannedPhotoCount + scannedVideoCount)
        let checkedBytes = max(scannedCheckedBytes, scannedTotalBytes)
        return "\(filesChecked) files checked • \(candidates) import candidates • \(formattedBytes(checkedBytes)) scanned"
    }

    var importingScanHeartbeatText: String {
        LauncherImportPresentation.scanHeartbeatText(
            now: Date(),
            lastProgressEventAt: lastProgressEventAt
        )
    }

    var importingPhaseDescription: String {
        LauncherImportPresentation.phaseDescription(for: latestCorePhase)
    }

    var importingProgressFraction: Double {
        LauncherImportPresentation.progressFraction(
            phase: latestCorePhase,
            totalCount: importTotalCount,
            copiedCount: copiedCount,
            verifiedCount: verifiedCount,
            committedCount: committedCount,
            isSuccess: uiState == .success
        )
    }

    var importingETA: String {
        LauncherImportPresentation.estimatedRemainingText(
            now: Date(),
            runStartedAt: runStartedAt,
            phase: latestCorePhase,
            copiedCount: copiedCount,
            progressFraction: importingProgressFraction
        )
    }

    var importingCurrentFileText: String? {
        let path = currentFilePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else {
            return nil
        }
        return path
    }

    var importingScanActivityText: String? {
        guard isImportScanPhase, let path = importingCurrentFileText else {
            return nil
        }
        return "Now scanning: \(path)"
    }

    var importSourceDisplayName: String {
        Self.displayName(forImportPath: sourcePath, fallback: "Source")
    }

    var importDestinationDisplayName: String {
        Self.displayName(forImportPath: destinationPath, fallback: "Destination")
    }

    var importSourceDisplayPath: String {
        Self.normalizedImportPath(sourcePath)
    }

    var importDestinationDisplayPath: String {
        Self.normalizedImportPath(destinationPath)
    }

    var committedOutcomeCount: Int {
        if finalizedCommittedCount > 0 || finalizedDuplicateNotCopiedCount > 0 {
            return finalizedCommittedCount
        }
        return committedCount
    }

    var duplicateNotCopiedOutcomeCount: Int {
        if finalizedCommittedCount > 0 || finalizedDuplicateNotCopiedCount > 0 {
            return finalizedDuplicateNotCopiedCount
        }
        return duplicateNotCopiedCount
    }

    var isIdempotentRerun: Bool {
        idempotentRerunDetected || (committedOutcomeCount == 0 && duplicateNotCopiedOutcomeCount > 0)
    }

    var completionItemsText: String {
        if isIdempotentRerun {
            let duplicates = duplicateNotCopiedOutcomeCount
            if duplicates == 1 {
                return "No new items imported; 1 item already exists in the library"
            }
            return "No new items imported; \(duplicates) items already exist in the library"
        }

        let imported = committedOutcomeCount
        return imported == 1 ? "1 item imported" : "\(imported) items imported"
    }

    var completionOutcomeText: String {
        if isIdempotentRerun {
            return "Idempotent rerun confirmed. Existing files were preserved without overwrite."
        }

        let duplicates = duplicateNotCopiedOutcomeCount
        if duplicates > 0 {
            return duplicates == 1
                ? "1 duplicate was detected and skipped safely."
                : "\(duplicates) duplicates were detected and skipped safely."
        }

        return "New files were committed to your library."
    }

    var completionReceiptText: String {
        receiptPath.isEmpty ? "Receipt path unavailable" : "Receipt saved"
    }

    var completionDurationText: String? {
        guard let finalizedTotalDurationMs else {
            return nil
        }
        return LauncherImportPresentation.completionDurationText(milliseconds: finalizedTotalDurationMs)
    }

    var failureTitle: String {
        wasStoppedByUser ? "Import Stopped" : "Import Needs Attention"
    }

    var failureMessage: String {
        if !failureReason.isEmpty {
            return failureReason
        }
        return "The import did not finish."
    }

    func prepareDefaultsOnLaunch() {
        guard !hasPreparedLaunchDefaults else {
            return
        }

        hasPreparedLaunchDefaults = true
        applySuggestedDestinationIfNeeded()
        applySuggestedSourceIfNeeded()
    }

    func pickSourcePath() {
        guard let selected = selectDirectory(title: "Select Source Folder", prompt: "Use Source") else {
            return
        }
        sourcePath = selected
    }

    func pickDestinationPath() {
        guard let selected = selectDirectory(title: "Select Destination Folder", prompt: "Use Destination") else {
            return
        }
        destinationPath = selected
    }

    func startIngest() {
        guard canStart else {
            handlePathInputChanged(sourceChanged: false)
            if statusMessage == "Import ready" {
                statusMessage = "Choose a readable source and writable destination first."
            }
            return
        }

        guard let cliExecutable = RollkeepCLIExecutableLocator.resolve() else {
            uiState = .failure
            currentPhase = .finished
            statusMessage = "RollKeep CLI executable was not found."
            appendOutput("[system] Could not locate the sibling `rollkeep` executable next to the launcher binary.")
            return
        }

        sourceScanTask?.cancel()
        resetRunState()
        seedRunCountersFromPreviewSummary()

        latestCorePhase = .scan
        currentPhase = .scan
        uiState = .running
        statusMessage = "Preparing import..."
        stopReceiptPolling()
        runStartedAt = Date()
        lastProgressEventAt = runStartedAt
        ensureReceiptPollingTimer()
        appendOutput("[system] Using CLI executable: \(cliExecutable.path)")

        let process = Process()
        process.executableURL = cliExecutable
        process.arguments = ["--source", sourcePath, "--dest", destinationPath, "--pdf"]
        executedCommand = commandLine(executablePath: cliExecutable.path, sourcePath: sourcePath, destinationPath: destinationPath)

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                return
            }
            let chunk = String(decoding: data, as: UTF8.self)
            Task { @MainActor [weak self] in
                self?.consume(chunk: chunk, stream: .stdout)
            }
        }

        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                return
            }
            let chunk = String(decoding: data, as: UTF8.self)
            Task { @MainActor [weak self] in
                self?.consume(chunk: chunk, stream: .stderr)
            }
        }

        process.terminationHandler = { [weak self] terminated in
            Task { @MainActor [weak self] in
                self?.handleTermination(process: terminated, stdoutPipe: stdoutPipe, stderrPipe: stderrPipe)
            }
        }

        do {
            try process.run()
            activeProcess = process
            appendOutput("[system] Running: \(executedCommand)")
        } catch {
            stopReceiptPolling()
            uiState = .failure
            currentPhase = .finished
            statusMessage = "Failed to launch RollKeep process."
            appendOutput("[system] Failed to run process: \(error.localizedDescription)")
        }
    }

    func stopIngest() {
        guard isRunning else {
            return
        }

        guard let activeProcess else {
            return
        }

        stopRequestedByUser = true
        statusMessage = "Stopping import..."
        appendOutput("[system] Stop requested by user.")
        activeProcess.terminate()
    }

    func openReceipt() {
        guard canOpenReceipt else {
            statusMessage = "Receipt file is not available."
            return
        }

        guard let openPath = preferredReceiptOpenPath else {
            statusMessage = "Receipt file is not available."
            return
        }

        finderOpening.reveal([URL(fileURLWithPath: openPath)])
    }

    func openDestination() {
        guard canOpenDestination else {
            statusMessage = "Destination folder is not available."
            return
        }

        finderOpening.reveal([URL(fileURLWithPath: destinationPath)])
    }

    func openSource() {
        guard canOpenSource else {
            statusMessage = "Source folder is not available."
            return
        }

        finderOpening.reveal([URL(fileURLWithPath: sourcePath)])
    }

    func openStagingFolder() {
        guard canOpenStagingFolder else {
            statusMessage = "Staging folder is not available."
            return
        }

        finderOpening.reveal([URL(fileURLWithPath: stagingPath)])
    }

    func openNewFinalMediaDirectories() {
        let directories = newFinalMediaDirectories
        guard !directories.isEmpty else {
            statusMessage = "No new destination media folders were created."
            return
        }

        for path in directories {
            _ = finderOpening.openDirectory(URL(fileURLWithPath: path, isDirectory: true))
        }
    }

    func importAnotherCard() {
        guard !isRunning else {
            return
        }

        resetRunState()
        currentPhase = .idle
        uiState = .idle
        sourcePath = ""
        statusMessage = "Choose source and destination to begin."
        applySuggestedSourceIfNeeded()
    }

    private func resetRunState() {
        parser = CLIOutputParser()
        receiptParser = ReceiptEventParser()
        parsedResult = nil
        stdoutCarry = ""
        stderrCarry = ""
        receiptCarry = ""
        receiptPath = ""
        pdfSummaryPath = ""
        stagingPath = ""
        failureReason = ""
        outputText = ""
        receiptPreviewText = ""
        receiptPreviewLines = []
        plannedStageAndCommitCount = 0
        scannedCandidateCount = 0
        duplicateNotCopiedCount = 0
        copiedCount = 0
        verifiedCount = 0
        committedCount = 0
        currentFilePath = ""
        finalizedCommittedCount = 0
        finalizedDuplicateNotCopiedCount = 0
        finalizedTotalDurationMs = nil
        idempotentRerunDetected = false
        scannedPhotoCount = 0
        scannedVideoCount = 0
        scannedTotalBytes = 0
        scannedFilesCheckedCount = 0
        scannedCheckedBytes = 0
        receiptErrors = []
        touchedPaths = []
        createdDirectories = []
        seenErrorEventIndexes = []
        monitoredReceiptPath = ""
        receiptReadOffset = 0
        runStartedAt = nil
        lastProgressEventAt = nil
        progressCounters = LauncherProgressCounters()
        stopRequestedByUser = false
        wasStoppedByUser = false
    }

    private func handlePathInputChanged(sourceChanged: Bool) {
        guard !isRunning else {
            return
        }

        if sourceChanged {
            scheduleSourceScanIfNeeded()
        }

        if sourcePathValid && destinationPathValid {
            if let invalidPairMessage = LauncherPathValidation.invalidPathPairMessage(
                sourcePath: sourcePath,
                destinationPath: destinationPath
            ) {
                uiState = .idle
                statusMessage = invalidPairMessage
                return
            }

            uiState = .ready
            statusMessage = "Import ready"
            return
        }

        uiState = .idle

        let hasSource = !sourcePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasDestination = !destinationPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        if !hasSource && !hasDestination {
            statusMessage = "Choose source and destination to begin."
            return
        }

        if hasSource && !sourcePathValid {
            statusMessage = "Source must be a readable folder."
            return
        }

        if hasDestination && !destinationPathValid {
            statusMessage = "Destination must be a writable folder."
            return
        }

        if hasSource && sourcePathValid && !hasDestination {
            statusMessage = "Choose a writable destination to begin."
            return
        }

        if hasDestination && destinationPathValid && !hasSource {
            statusMessage = "Choose a readable source to begin."
            return
        }

        statusMessage = "Choose a readable source and writable destination."
    }

    private func applySuggestedSourceIfNeeded() {
        guard !isRunning else {
            return
        }

        let trimmedSourcePath = sourcePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedSourcePath.isEmpty else {
            return
        }

        guard let suggestedSourcePath = sourceDefaulting.suggestedSourcePath(),
              LauncherPathValidation.isValidSourcePath(suggestedSourcePath) else {
            return
        }

        sourcePath = suggestedSourcePath
    }

    private func applySuggestedDestinationIfNeeded() {
        guard !isRunning else {
            return
        }

        let trimmedDestinationPath = destinationPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedDestinationPath.isEmpty else {
            return
        }

        guard let suggestedDestinationPath = destinationDefaulting.suggestedDestinationPath(),
              !suggestedDestinationPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }

        destinationPath = suggestedDestinationPath
    }

    private func rememberDestinationIfNeeded() {
        let trimmedDestinationPath = destinationPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedDestinationPath.isEmpty else {
            return
        }

        destinationRemembering.saveLastDestinationPath(trimmedDestinationPath)
    }

    private func scheduleSourceScanIfNeeded() {
        sourceScanTask?.cancel()

        let trimmedSourcePath = sourcePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSourcePath.isEmpty else {
            sourceScanState = .idle
            scannedPhotoCount = 0
            scannedVideoCount = 0
            scannedTotalBytes = 0
            scannedFilesCheckedCount = 0
            scannedCheckedBytes = 0
            lastPreviewSummary = nil
            return
        }

        guard LauncherPathValidation.isValidSourcePath(trimmedSourcePath) else {
            sourceScanState = .failed("Source must be a readable folder.")
            scannedPhotoCount = 0
            scannedVideoCount = 0
            scannedTotalBytes = 0
            scannedFilesCheckedCount = 0
            scannedCheckedBytes = 0
            lastPreviewSummary = nil
            return
        }

        sourceScanState = .scanning(nil)
        scannedPhotoCount = 0
        scannedVideoCount = 0
        scannedTotalBytes = 0
        scannedFilesCheckedCount = 0
        scannedCheckedBytes = 0
        lastPreviewSummary = nil

        sourceScanTask = Task { [weak self] in
            guard let self else {
                return
            }

            let scanner = sourceScanner
            let result = await Task.detached(priority: .utility) {
                Result {
                    try scanner.scan(sourcePath: trimmedSourcePath, mode: .preview) { snapshot in
                        Task { @MainActor [weak self] in
                            guard let self,
                                  self.sourcePath.trimmingCharacters(in: .whitespacesAndNewlines) == trimmedSourcePath,
                                  self.uiState != .running else {
                                return
                            }

                            let summary = LauncherSourceScopeSummary(snapshot: snapshot)
                            self.sourceScanState = .scanning(summary)
                            self.scannedPhotoCount = summary.photoCount
                            self.scannedVideoCount = summary.videoCount
                            self.scannedTotalBytes = summary.totalBytes
                            self.scannedFilesCheckedCount = max(self.scannedFilesCheckedCount, snapshot.filesChecked)
                            self.scannedCheckedBytes = max(self.scannedCheckedBytes, snapshot.bytesChecked)
                        }
                    }
                }
            }.value

            guard !Task.isCancelled,
                  self.sourcePath.trimmingCharacters(in: .whitespacesAndNewlines) == trimmedSourcePath else {
                return
            }

            switch result {
            case .success(let preparation):
                let launcherSummary = LauncherSourceScopeSummary(preparation: preparation)
                sourceScanState = .ready(launcherSummary)
                scannedPhotoCount = launcherSummary.photoCount
                scannedVideoCount = launcherSummary.videoCount
                scannedTotalBytes = launcherSummary.totalBytes
                scannedFilesCheckedCount = max(scannedFilesCheckedCount, preparation.scanSummary.candidates.count)
                scannedCheckedBytes = max(scannedCheckedBytes, launcherSummary.totalBytes)
                lastPreviewSummary = launcherSummary
            case .failure(let error):
                lastPreviewSummary = nil
                if let scopeError = error as? SourceScannerError {
                    switch scopeError {
                    case .unreadableSourceRoot:
                        sourceScanState = .failed("Source must be a readable folder.")
                    case .symbolicLinkDetected:
                        sourceScanState = .failed("Source scan blocked symlink content.")
                    case .sourceBoundaryViolation:
                        sourceScanState = .failed("Source scan blocked out-of-bound content.")
                    }
                } else {
                    sourceScanState = .failed("Source scan failed. You can still start import.")
                }
            }
        }
    }

    private func seedRunCountersFromPreviewSummary() {
        guard let summary = lastPreviewSummary else {
            return
        }

        scannedCandidateCount = max(scannedCandidateCount, summary.itemCount)
    }

    private func handleTermination(process: Process, stdoutPipe: Pipe, stderrPipe: Pipe) {
        let finishedAt = Date()
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil

        let stdoutTail = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        if !stdoutTail.isEmpty {
            consume(chunk: String(decoding: stdoutTail, as: UTF8.self), stream: .stdout)
        }

        let stderrTail = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        if !stderrTail.isEmpty {
            consume(chunk: String(decoding: stderrTail, as: UTF8.self), stream: .stderr)
        }

        flushPendingOutput(stream: .stdout)
        flushPendingOutput(stream: .stderr)
        pollReceiptIfNeeded()
        stopReceiptPolling()

        let exitCode = Int(process.terminationStatus)
        appendOutput("[system] Process finished with exit code \(exitCode).")

        let result = parsedResult ?? (exitCode == 0 ? .success : .failure)
        uiState = result == .success ? .success : .failure
        currentPhase = .finished

        if finalizedTotalDurationMs == nil, let runStartedAt {
            let elapsedMs = Int((finishedAt.timeIntervalSince(runStartedAt) * 1_000).rounded())
            finalizedTotalDurationMs = max(0, elapsedMs)
        }

        let userRequestedStop = stopRequestedByUser
        stopRequestedByUser = false
        wasStoppedByUser = userRequestedStop

        switch result {
        case .success:
            latestCorePhase = .finalize
            statusMessage = isIdempotentRerun
                ? "Import complete. All items were already in your library."
                : "Import complete."
        case .failure:
            if userRequestedStop {
                if failureReason.isEmpty {
                    failureReason = "Import stopped by user."
                }
                statusMessage = "Import stopped before completion."
            } else {
                if failureReason.isEmpty, let receiptError = receiptErrors.first?.message {
                    failureReason = receiptError
                }
                statusMessage = shortFailureSummary(exitCode: exitCode)
            }
        }

        activeProcess = nil
    }

    private func shortFailureSummary(exitCode: Int) -> String {
        if !failureReason.isEmpty {
            return "Failed: \(truncated(failureReason, limit: 140))"
        }
        return "Failed (exit code \(exitCode))."
    }

    private func truncated(_ text: String, limit: Int) -> String {
        guard text.count > limit else {
            return text
        }

        let endIndex = text.index(text.startIndex, offsetBy: limit)
        return "\(text[text.startIndex..<endIndex])..."
    }

    private func consume(chunk: String, stream: OutputStreamKind) {
        var buffer = stream == .stdout ? stdoutCarry : stderrCarry
        buffer.append(chunk)

        let lines = consumeCompleteLines(from: &buffer)

        if stream == .stdout {
            stdoutCarry = buffer
        } else {
            stderrCarry = buffer
        }

        for line in lines {
            handleLine(line, stream: stream)
        }
    }

    private func flushPendingOutput(stream: OutputStreamKind) {
        let pending: String
        if stream == .stdout {
            pending = stdoutCarry
            stdoutCarry = ""
        } else {
            pending = stderrCarry
            stderrCarry = ""
        }

        let trimmed = pending.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return
        }

        handleLine(trimmed, stream: stream)
    }

    private func consumeCompleteLines(from buffer: inout String) -> [String] {
        let parts = buffer.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        guard !parts.isEmpty else {
            return []
        }

        let endedWithNewline = buffer.last?.isNewline == true
        if endedWithNewline {
            buffer = ""
            return parts.map(String.init)
        }

        let complete = parts.dropLast().map(String.init)
        buffer = String(parts.last ?? "")
        return complete
    }

    private func handleLine(_ line: String, stream: OutputStreamKind) {
        appendOutput("[\(stream.rawValue)] \(line)")

        let update = parser.parse(line: line)
        if let phase = update.phase {
            currentPhase = phase
            if phase != .finished {
                latestCorePhase = phase
            }
            markProgressEvent()
            updateRunningStatus()
        }
        if let path = update.receiptPath, !path.isEmpty {
            updateReceiptPath(path)
        }
        if let pdfPath = update.pdfSummaryPath, !pdfPath.isEmpty {
            updatePDFSummaryPath(pdfPath)
        }
        if let stagePath = update.stagingPath, !stagePath.isEmpty {
            stagingPath = stagePath
        }
        if let reason = update.failureReason, !reason.isEmpty {
            failureReason = reason
        }
        if let idempotent = update.idempotentRerun {
            idempotentRerunDetected = idempotent
        }
        if let result = update.result {
            parsedResult = result
        }
    }

    private func updateRunningStatus() {
        guard uiState == .running else {
            return
        }

        statusMessage = "\(importingPhaseDescription)."
    }

    private func updateReceiptPath(_ path: String) {
        guard !path.isEmpty else {
            return
        }
        receiptPath = path
        startReceiptPolling(path: path)
    }

    private func updatePDFSummaryPath(_ path: String) {
        guard !path.isEmpty else {
            return
        }
        pdfSummaryPath = path
    }

    private func startReceiptPolling(path: String) {
        guard !path.isEmpty else {
            return
        }

        if monitoredReceiptPath != path {
            monitoredReceiptPath = path
            receiptReadOffset = 0
            receiptCarry = ""
            appendReceiptLine("[receipt] monitoring \(path)")
        }

        ensureReceiptPollingTimer()
    }

    private func stopReceiptPolling() {
        receiptPollTimer?.invalidate()
        receiptPollTimer = nil
    }

    private func ensureReceiptPollingTimer() {
        if receiptPollTimer == nil {
            let timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.pollReceiptIfNeeded()
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            receiptPollTimer = timer
        }

        pollReceiptIfNeeded()
    }

    private func pollReceiptIfNeeded() {
        defer {
            updateRunningStatus()
        }

        discoverReceiptPathIfNeeded()

        guard !monitoredReceiptPath.isEmpty else {
            return
        }

        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: monitoredReceiptPath) else {
            return
        }

        if let attributes = try? fileManager.attributesOfItem(atPath: monitoredReceiptPath),
           let fileSize = attributes[.size] as? NSNumber,
           fileSize.uint64Value < receiptReadOffset {
            receiptReadOffset = 0
            receiptCarry = ""
        }

        do {
            let fileURL = URL(fileURLWithPath: monitoredReceiptPath, isDirectory: false)
            let handle = try FileHandle(forReadingFrom: fileURL)
            defer {
                try? handle.close()
            }

            try handle.seek(toOffset: receiptReadOffset)
            let data = try handle.readToEnd() ?? Data()
            receiptReadOffset += UInt64(data.count)
            guard !data.isEmpty else {
                return
            }

            consumeReceiptChunk(String(decoding: data, as: UTF8.self))
        } catch {
            appendOutput("[system] Failed reading receipt stream: \(error.localizedDescription)")
        }
    }

    private func consumeReceiptChunk(_ chunk: String) {
        receiptCarry.append(chunk)
        let lines = consumeCompleteLines(from: &receiptCarry)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                continue
            }

            appendReceiptLine(trimmed)
            applyReceiptUpdate(receiptParser.parse(line: trimmed))
        }
    }

    private func applyReceiptUpdate(_ update: ParsedReceiptUpdate) {
        if let phase = update.phase {
            currentPhase = phase
            latestCorePhase = phase
            markProgressEvent()
        }

        var scanTelemetryChanged = false
        if let scannedFilesCheckedCountUpdate = update.scannedFilesCheckedCount {
            let normalized = max(scannedFilesCheckedCountUpdate, 0)
            if normalized > scannedFilesCheckedCount {
                scannedFilesCheckedCount = normalized
                scanTelemetryChanged = true
            }
        }
        if let scannedCheckedBytesUpdate = update.scannedCheckedBytes {
            let normalized = max(scannedCheckedBytesUpdate, Int64(0))
            if normalized > scannedCheckedBytes {
                scannedCheckedBytes = normalized
                scanTelemetryChanged = true
            }
        }

        if let photoCount = update.scanPhotoCount {
            scannedPhotoCount = max(scannedPhotoCount, photoCount)
        }
        if let videoCount = update.scanVideoCount {
            scannedVideoCount = max(scannedVideoCount, videoCount)
        }
        if let photoBytes = update.scanPhotoBytes {
            scannedTotalBytes = max(scannedTotalBytes, photoBytes + (update.scanVideoBytes ?? 0))
        } else if let videoBytes = update.scanVideoBytes {
            scannedTotalBytes = max(scannedTotalBytes, videoBytes)
        }

        if let scanned = update.scannedCandidateCount,
           update.scanPhotoCount != nil || update.scanVideoCount != nil {
            let summary = LauncherSourceScopeSummary(
                itemCount: scanned,
                photoCount: update.scanPhotoCount ?? scannedPhotoCount,
                videoCount: update.scanVideoCount ?? scannedVideoCount,
                totalBytes: (update.scanPhotoBytes ?? 0) + (update.scanVideoBytes ?? 0)
            )
            sourceScanState = .ready(summary)
        }

        let progressChanged = progressCounters.apply(update)
        syncProgressCountersToPublished()

        if progressChanged {
            markProgressEvent()
        }

        if let path = update.currentFilePath?.trimmingCharacters(in: .whitespacesAndNewlines),
           !path.isEmpty {
            if path != currentFilePath {
                scanTelemetryChanged = true
            }
            currentFilePath = path
        }
        if scanTelemetryChanged {
            markProgressEvent()
        }

        if let committed = update.finalizedCommittedCount {
            finalizedCommittedCount = max(0, committed)
        }
        if let duplicates = update.finalizedDuplicateNotCopiedCount {
            finalizedDuplicateNotCopiedCount = max(0, duplicates)
        }
        if let idempotent = update.finalizedIdempotentRerun {
            idempotentRerunDetected = idempotent
        }
        if let durationMs = update.finalizedTotalDurationMs {
            finalizedTotalDurationMs = max(0, durationMs)
        }
        if let pdfPath = update.pdfSummaryPath {
            updatePDFSummaryPath(pdfPath)
        }

        if let error = update.errorItem,
           seenErrorEventIndexes.insert(error.eventIndex).inserted {
            receiptErrors.append(error)
            if failureReason.isEmpty {
                failureReason = error.message
            }
            if let inferred = inferStagingSessionPath(from: error.paths), stagingPath.isEmpty {
                stagingPath = inferred
            }
        }

        if let paths = update.touchedPaths {
            touchedPaths = paths
            if let inferred = inferStagingSessionPath(from: paths), stagingPath.isEmpty {
                stagingPath = inferred
            }
        }
        if let created = update.createdDirectories {
            createdDirectories = created
        }

        updateRunningStatus()
    }

    private func filterNewFinalMediaDirectories(_ paths: [String], destinationPath: String) -> [String] {
        let trimmedDestination = destinationPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !paths.isEmpty, !trimmedDestination.isEmpty else {
            return []
        }

        let fileManager = FileManager.default
        let normalizedDestination = URL(fileURLWithPath: trimmedDestination, isDirectory: true).standardizedFileURL.path
        let destinationPrefix = normalizedDestination.hasSuffix("/") ? normalizedDestination : normalizedDestination + "/"

        var seen = Set<String>()
        var eligible: [String] = []

        for path in paths {
            let normalizedPath = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path

            guard normalizedPath == normalizedDestination || normalizedPath.hasPrefix(destinationPrefix) else {
                continue
            }
            guard !normalizedPath.contains("/_ingest_staging/"),
                  !normalizedPath.contains("/_ingest_receipts/") else {
                continue
            }
            guard normalizedPath.hasSuffix("/Photos") || normalizedPath.hasSuffix("/Videos") else {
                continue
            }

            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: normalizedPath, isDirectory: &isDirectory), isDirectory.boolValue else {
                continue
            }

            if seen.insert(normalizedPath).inserted {
                eligible.append(normalizedPath)
            }
        }

        return eligible.sorted()
    }

    private func syncProgressCountersToPublished() {
        scannedCandidateCount = progressCounters.scannedCandidateCount
        plannedStageAndCommitCount = progressCounters.plannedStageAndCommitCount
        duplicateNotCopiedCount = progressCounters.duplicateNotCopiedCount
        copiedCount = progressCounters.copiedCount
        verifiedCount = progressCounters.verifiedCount
        committedCount = progressCounters.committedCount
    }

    private func markProgressEvent() {
        lastProgressEventAt = Date()
    }

#if DEBUG
    func applyReceiptUpdateForTesting(_ update: ParsedReceiptUpdate) {
        applyReceiptUpdate(update)
    }
#endif

    private func inferStagingSessionPath(from paths: [String]) -> String? {
        for path in paths {
            if let inferred = inferStagingSessionPath(from: path) {
                return inferred
            }
        }
        return nil
    }

    private func inferStagingSessionPath(from path: String) -> String? {
        let marker = "/_ingest_staging/"
        guard let markerRange = path.range(of: marker) else {
            return nil
        }

        let suffix = path[markerRange.upperBound...]
        guard let sessionComponent = suffix.split(separator: "/").first else {
            return nil
        }

        return String(path[..<markerRange.upperBound]) + sessionComponent
    }

    private func appendReceiptLine(_ line: String) {
        receiptPreviewLines.append(line)
        if receiptPreviewLines.count > 240 {
            receiptPreviewLines.removeFirst(receiptPreviewLines.count - 240)
        }
        receiptPreviewText = receiptPreviewLines.joined(separator: "\n")
    }

    private func appendOutput(_ line: String) {
        if outputText.isEmpty {
            outputText = line
        } else {
            outputText.append("\n")
            outputText.append(line)
        }
    }

    private func formattedBytes(_ value: Int64) -> String {
        Self.byteCountFormatter.string(fromByteCount: value)
    }

    private func discoverReceiptPathIfNeeded() {
        guard monitoredReceiptPath.isEmpty,
              uiState == .running,
              !destinationPath.isEmpty else {
            return
        }

        let receiptsURL = URL(fileURLWithPath: destinationPath, isDirectory: true)
            .appendingPathComponent("_ingest_receipts", isDirectory: true)
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(
            at: receiptsURL,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        let startedAt = runStartedAt ?? Date.distantPast
        let candidates = entries.filter { $0.pathExtension == "ndjson" }
        let recentCandidates = candidates.filter { url in
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
                  let modifiedAt = values.contentModificationDate else {
                return false
            }
            return modifiedAt >= startedAt.addingTimeInterval(-2)
        }

        guard let newest = recentCandidates.max(by: { lhs, rhs in
            let leftDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let rightDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return leftDate < rightDate
        }) else {
            return
        }

        updateReceiptPath(newest.path)
    }

    private func commandLine(executablePath: String, sourcePath: String, destinationPath: String) -> String {
        "\(shellQuoted(executablePath)) --source \(shellQuoted(sourcePath)) --dest \(shellQuoted(destinationPath)) --pdf"
    }

    private var preferredReceiptOpenPath: String? {
        let fileManager = FileManager.default
        if !pdfSummaryPath.isEmpty, fileManager.fileExists(atPath: pdfSummaryPath) {
            return pdfSummaryPath
        }
        if !receiptPath.isEmpty, fileManager.fileExists(atPath: receiptPath) {
            return receiptPath
        }
        return nil
    }

    private func shellQuoted(_ value: String) -> String {
        guard !value.isEmpty else {
            return "''"
        }

        let escaped = value.replacingOccurrences(of: "'", with: "'\\''")
        return "'\(escaped)'"
    }

    private static func normalizedImportPath(_ rawPath: String) -> String {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return ""
        }

        return URL(fileURLWithPath: trimmed, isDirectory: true).standardizedFileURL.path
    }

    private static func displayName(forImportPath rawPath: String, fallback: String) -> String {
        let normalizedPath = normalizedImportPath(rawPath)
        guard !normalizedPath.isEmpty else {
            return fallback
        }

        if normalizedPath == "/" {
            return "/"
        }

        let component = URL(fileURLWithPath: normalizedPath, isDirectory: true).lastPathComponent
        if !component.isEmpty {
            return component
        }

        return normalizedPath
    }

    private func selectDirectory(title: String, prompt: String) -> String? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.prompt = prompt
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false

        let response = panel.runModal()
        guard response == .OK else {
            return nil
        }

        return panel.url?.path
    }
}

private struct LauncherPanelStyle {
    let fillOpacity: Double
    let strokeOpacity: Double
    let iconFillOpacity: Double

    static let source = LauncherPanelStyle(fillOpacity: 0.06, strokeOpacity: 0.16, iconFillOpacity: 0.12)
    static let destination = LauncherPanelStyle(fillOpacity: 0.05, strokeOpacity: 0.14, iconFillOpacity: 0.1)
    static let scan = LauncherPanelStyle(fillOpacity: 0.045, strokeOpacity: 0.12, iconFillOpacity: 0.09)

    var accent: Color { .blue }
}

private struct LauncherPanelBackground: View {
    let style: LauncherPanelStyle

    var body: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(Color(nsColor: .controlBackgroundColor))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(style.accent.opacity(style.fillOpacity))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(style.accent.opacity(style.strokeOpacity), lineWidth: 0.8)
            )
            .shadow(color: Color.black.opacity(0.05), radius: 10, y: 2)
    }
}

private struct LauncherSelectionCard: View {
    let systemImage: String
    let style: LauncherPanelStyle
    let title: String
    let path: String
    let placeholder: String
    let buttonTitle: String
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(style.accent.opacity(style.iconFillOpacity))

                Image(systemName: systemImage)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(style.accent)
            }
            .frame(width: 38, height: 38)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                if path.isEmpty {
                    Text(placeholder)
                        .font(.body)
                        .foregroundStyle(.secondary)
                } else {
                    Text(path)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: 12)

            Button(buttonTitle, action: action)
                .buttonStyle(.bordered)
                .disabled(!isEnabled)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LauncherPanelBackground(style: style))
    }
}

private struct LauncherSourceInventoryPanel: View {
    @ObservedObject var viewModel: LauncherViewModel
    let style: LauncherPanelStyle

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(style.accent.opacity(style.iconFillOpacity))

                    Image(systemName: "viewfinder")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(style.accent)
                }
                .frame(width: 38, height: 38)

                Text("Scan Preview")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Spacer(minLength: 12)

                if viewModel.isSourceScanning {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            inventoryContent
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LauncherPanelBackground(style: style))
    }

    @ViewBuilder
    private var inventoryContent: some View {
        if let summary = viewModel.setupInventory {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    LauncherSourceInventoryStat(title: "Photos", value: "\(summary.photoCount)")
                    LauncherSourceInventoryStat(title: "Videos", value: "\(summary.videoCount)")
                    LauncherSourceInventoryStat(title: "Cameras", value: "\(summary.detectedCameraCount)")
                    LauncherSourceInventoryStat(title: "Size", value: viewModel.setupInventorySizeText)
                }

                if !viewModel.setupInventoryCameraEntries.isEmpty {
                    Divider()

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Camera Inventory")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)

                        ScrollView(.vertical, showsIndicators: viewModel.setupInventoryCameraEntries.count > LauncherWindowMetrics.maxVisibleCameraRows) {
                            LazyVStack(alignment: .leading, spacing: 8) {
                                ForEach(viewModel.setupInventoryCameraEntries) { entry in
                                    HStack(spacing: 12) {
                                        Text(entry.displayLabel)
                                            .font(.subheadline)
                                            .lineLimit(1)
                                            .truncationMode(.tail)
                                        Spacer()
                                        Text("\(entry.fileCount)")
                                            .font(.subheadline.weight(.medium))
                                            .foregroundStyle(.secondary)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: LauncherWindowMetrics.cameraInventoryMaxHeight)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text(inventoryPlaceholderText)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: LauncherWindowMetrics.emptyInventoryCardMinHeight, alignment: .topLeading)
        }
    }

    private var inventoryPlaceholderText: String {
        if viewModel.isSourceScanning {
            return viewModel.setupScopeSummaryText
        }

        if viewModel.sourcePath.isEmpty {
            return "Choose a source to preview photos, videos, cameras, and total size before import."
        }

        return "Scan details appear here once RollKeep can inspect the selected source."
    }
}

private struct LauncherSourceInventoryStat: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.headline)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct LauncherImportRoutePanel: View {
    let sourceName: String
    let sourcePath: String
    let destinationName: String
    let destinationPath: String

    var body: some View {
        ViewThatFits(in: .horizontal) {
            horizontalRoute
            verticalRoute
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LauncherPanelBackground(style: .scan))
    }

    private var horizontalRoute: some View {
        HStack(alignment: .center, spacing: 12) {
            LauncherImportRouteEndpoint(
                title: "Source",
                systemImage: "externaldrive",
                style: .source,
                name: sourceName,
                path: sourcePath
            )

            routeArrow(symbolName: "arrow.right")

            LauncherImportRouteEndpoint(
                title: "Destination",
                systemImage: "folder",
                style: .destination,
                name: destinationName,
                path: destinationPath
            )
        }
    }

    private var verticalRoute: some View {
        VStack(alignment: .leading, spacing: 12) {
            LauncherImportRouteEndpoint(
                title: "Source",
                systemImage: "externaldrive",
                style: .source,
                name: sourceName,
                path: sourcePath
            )

            routeArrow(symbolName: "arrow.down")
                .frame(maxWidth: .infinity, alignment: .center)

            LauncherImportRouteEndpoint(
                title: "Destination",
                systemImage: "folder",
                style: .destination,
                name: destinationName,
                path: destinationPath
            )
        }
    }

    private func routeArrow(symbolName: String) -> some View {
        Image(systemName: symbolName)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.secondary)
        .frame(minWidth: 56)
    }
}

private struct LauncherImportRouteEndpoint: View {
    let title: String
    let systemImage: String
    let style: LauncherPanelStyle
    let name: String
    let path: String

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(style.accent.opacity(style.iconFillOpacity))

                Image(systemName: systemImage)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(style.accent)
            }
            .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(pathText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var pathText: String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Path unavailable" : trimmed
    }
}

struct LauncherContentView: View {
    @StateObject private var viewModel = LauncherViewModel()
    @State private var configuredWindowID: ObjectIdentifier?
    @State private var measuredContentHeight: CGFloat?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch viewModel.uiState {
            case .idle, .ready:
                setupSection
            case .running:
                importingSection
            case .success:
                completeSection
            case .failure:
                failureSection
            }
        }
        .padding(18)
        .frame(
            minWidth: LauncherWindowMetrics.minWidth,
            idealWidth: LauncherWindowMetrics.idealWidth,
            alignment: .topLeading
        )
        .background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: LauncherContentHeightPreferenceKey.self,
                    value: proxy.size.height
                )
            }
        )
        .background(
            LauncherWindowAccessor { window in
                configureWindow(window)
            }
        )
        .onPreferenceChange(LauncherContentHeightPreferenceKey.self) { height in
            let roundedHeight = ceil(height)
            guard roundedHeight > 0 else {
                return
            }

            let currentHeight = measuredContentHeight ?? 0
            guard abs(currentHeight - roundedHeight) > 0.5 else {
                return
            }

            measuredContentHeight = roundedHeight
        }
        .task {
            viewModel.prepareDefaultsOnLaunch()
        }
    }

    private var setupSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            LauncherSelectionCard(
                systemImage: "externaldrive",
                style: .source,
                title: "Source",
                path: viewModel.sourcePath,
                placeholder: "Choose source",
                buttonTitle: viewModel.sourcePath.isEmpty ? "Choose" : "Change",
                isEnabled: !viewModel.isRunning,
                action: viewModel.pickSourcePath
            )

            LauncherSelectionCard(
                systemImage: "folder",
                style: .destination,
                title: "Destination",
                path: viewModel.destinationPath,
                placeholder: "Choose destination",
                buttonTitle: viewModel.destinationPath.isEmpty ? "Choose" : "Change",
                isEnabled: !viewModel.isRunning,
                action: viewModel.pickDestinationPath
            )

            LauncherSourceInventoryPanel(viewModel: viewModel, style: .scan)

            startImportButton

            if viewModel.uiState != .ready {
                Text(viewModel.statusMessage)
                    .font(.footnote)
                    .foregroundStyle(viewModel.statusColor)
            }
        }
    }

    @ViewBuilder
    private var startImportButton: some View {
        if viewModel.isImportReady {
            Button(action: viewModel.startIngest) {
                Text("Import")
                    .frame(maxWidth: .infinity)
            }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
        } else {
            Button(action: viewModel.startIngest) {
                Text("Import")
                    .frame(maxWidth: .infinity)
            }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
                .disabled(true)
        }
    }

    private var importingSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(viewModel.importingTitle)
                .font(.title3.weight(.semibold))

            LauncherImportRoutePanel(
                sourceName: viewModel.importSourceDisplayName,
                sourcePath: viewModel.importSourceDisplayPath,
                destinationName: viewModel.importDestinationDisplayName,
                destinationPath: viewModel.importDestinationDisplayPath
            )

            ProgressView(value: viewModel.importingProgressFraction)
                .controlSize(.large)

            if viewModel.isImportScanPhase {
                Text(viewModel.importingScanProgressText)
                    .font(.body)

                Text(viewModel.importingScanHeartbeatText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                if let currentFile = viewModel.importingScanActivityText {
                    Text(currentFile)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            } else {
                Text(viewModel.importingProgressText)
                    .font(.body)

                Text(viewModel.importingETA)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                if let currentFile = viewModel.importingCurrentFileText {
                    Text(currentFile)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            HStack {
                Button("Stop Import", action: viewModel.stopIngest)
                    .buttonStyle(.bordered)
                    .disabled(!viewModel.isRunning)
                Spacer()
                Text(viewModel.importingPhaseDescription)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var completeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Import Complete")
                .font(.title3.weight(.semibold))

            HStack(spacing: 12) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 4) {
                    Text(viewModel.completionItemsText)
                        .font(.headline)
                    Text(viewModel.completionOutcomeText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if let durationText = viewModel.completionDurationText {
                        Text(durationText)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Text(viewModel.completionReceiptText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )

            if viewModel.canOpenNewFinalMediaDirectories {
                Button("Open New Folders in Finder", action: viewModel.openNewFinalMediaDirectories)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)
            }

            Button("Open Source", action: viewModel.openSource)
                .buttonStyle(.bordered)
                .frame(maxWidth: .infinity)
                .disabled(!viewModel.canOpenSource)

            Button("View Receipt", action: viewModel.openReceipt)
                .buttonStyle(.bordered)
                .frame(maxWidth: .infinity)
                .disabled(!viewModel.canOpenReceipt)

            Button("Import Another Card", action: viewModel.importAnotherCard)
                .buttonStyle(.bordered)
                .frame(maxWidth: .infinity)
        }
    }

    private var failureSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(viewModel.failureTitle)
                .font(.title3.weight(.semibold))

            Text(viewModel.failureMessage)
                .font(.body)
                .foregroundStyle(.primary)

            HStack(spacing: 10) {
                Button("View Receipt", action: viewModel.openReceipt)
                    .buttonStyle(.bordered)
                    .disabled(!viewModel.canOpenReceipt)

                Button("Open Destination", action: viewModel.openDestination)
                    .buttonStyle(.bordered)
                    .disabled(!viewModel.canOpenDestination)

                Spacer()

                Button("Import Another Card", action: viewModel.importAnotherCard)
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private var preferredContentHeight: CGFloat {
        LauncherWindowMetrics.preferredContentHeight(
            for: viewModel.uiState,
            measuredHeight: measuredContentHeight
        )
    }

    private func configureWindow(_ window: NSWindow) {
        let id = ObjectIdentifier(window)
        if configuredWindowID != id {
            configuredWindowID = id
        }

        let minimumContentSize = NSSize(
            width: LauncherWindowMetrics.minWidth,
            height: preferredContentHeight
        )
        if window.contentMinSize != minimumContentSize {
            window.contentMinSize = minimumContentSize
        }

        let targetContentSize = NSSize(
            width: LauncherWindowMetrics.idealWidth,
            height: preferredContentHeight
        )
        let currentContentSize = window.contentLayoutRect.size
        let sizeDelta = abs(currentContentSize.width - targetContentSize.width)
            + abs(currentContentSize.height - targetContentSize.height)
        guard sizeDelta > 0.5 else {
            return
        }

        window.setContentSize(targetContentSize)
    }
}

private struct LauncherWindowAccessor: NSViewRepresentable {
    let onResolveWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { [weak view] in
            guard let window = view?.window else {
                return
            }
            onResolveWindow(window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let window = nsView.window else {
                return
            }
            onResolveWindow(window)
        }
    }
}

@main
struct RollkeepLauncherApp: App {
    var body: some Scene {
        WindowGroup {
            LauncherContentView()
        }
        .defaultSize(width: LauncherWindowMetrics.idealWidth, height: LauncherWindowMetrics.setupHeight)
        .windowResizability(.contentSize)
    }
}

enum LauncherWindowMetrics {
    static let minWidth: CGFloat = 520
    static let idealWidth: CGFloat = 560
    static let compactHeight: CGFloat = 388
    static let setupHeight: CGFloat = 438
    static let emptyInventoryCardMinHeight: CGFloat = 132
    static let cameraInventoryMaxHeight: CGFloat = 80
    static let maxVisibleCameraRows = 3

    static func preferredContentHeight(for uiState: LauncherUIState) -> CGFloat {
        preferredContentHeight(for: uiState, measuredHeight: nil)
    }

    static func preferredContentHeight(for uiState: LauncherUIState, measuredHeight: CGFloat?) -> CGFloat {
        let fallbackHeight: CGFloat
        switch uiState {
        case .idle, .ready:
            fallbackHeight = setupHeight
        case .running, .success, .failure:
            fallbackHeight = compactHeight
        }

        guard let measuredHeight else {
            return fallbackHeight
        }

        return max(fallbackHeight, measuredHeight)
    }
}

private struct LauncherContentHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
