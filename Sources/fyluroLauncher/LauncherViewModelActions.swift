import AppKit
import Foundation
import FyluroCore
import FyluroEngine

extension LauncherViewModel {
    func prepareDefaultsOnLaunch() {
        guard !hasPreparedLaunchDefaults else {
            return
        }

        hasPreparedLaunchDefaults = true
        applySuggestedDestinationIfNeeded()
        applySuggestedSourceIfNeeded()
    }

    func pickSourcePath() {
        guard let selectedURL = runDirectoryPanel(Self.makeSourcePanel()) else {
            return
        }
        bookmarkStore.activateAccess(for: selectedURL, slot: .source)
        sourcePath = selectedURL.path
    }

    func pickDestinationPath() {
        guard let selectedURL = runDirectoryPanel(Self.makeDestinationPanel()) else {
            return
        }
        bookmarkStore.activateAccess(for: selectedURL, slot: .destination)
        bookmarkStore.saveDestinationBookmark(for: selectedURL)
        destinationPath = selectedURL.path
    }

    func acceptDroppedSource(_ urls: [URL]) {
        guard !isRunning else {
            return
        }

        switch LauncherFolderDropResolver.resolve(urls) {
        case .folder(let path):
            if let url = urls.first {
                bookmarkStore.activateAccess(for: url, slot: .source)
            }
            sourcePath = path
        case .rejected(let message):
            statusMessage = message
        }
    }

    func acceptDroppedDestination(_ urls: [URL]) {
        guard !isRunning else {
            return
        }

        switch LauncherFolderDropResolver.resolve(urls) {
        case .folder(let path):
            if let url = urls.first {
                bookmarkStore.activateAccess(for: url, slot: .destination)
                bookmarkStore.saveDestinationBookmark(for: url)
            }
            destinationPath = path
        case .rejected(let message):
            statusMessage = message
        }
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

        let actions = LauncherFinderDirectoryResolver.resolveActions(
            for: directories,
            destinationPath: destinationPath
        )

        for action in actions {
            switch action {
            case .openDirectory(let url):
                _ = finderOpening.openDirectory(url)
            case .revealInParent(let urls):
                finderOpening.reveal(urls)
            }
        }
    }

    func importAnotherCard() {
        guard !isRunning else {
            return
        }

        resetRunState()
        disableFilmMode()
        currentPhase = .idle
        uiState = .idle
        bookmarkStore.stopAccess(for: .source)
        sourcePath = ""
        statusMessage = "Choose source and destination to begin."
        applySuggestedSourceIfNeeded()
    }

    func handlePathInputChanged(sourceChanged: Bool) {
        guard !isRunning else {
            return
        }

        if sourceChanged {
            scheduleSourceScanIfNeeded()
        }

        scheduleDestinationSpaceCheckIfNeeded()

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

    func handleWorkspaceMountNotification(_ notification: Notification) {
        guard !isRunning, uiState == .idle || uiState == .ready else {
            return
        }

        if notification.name == NSWorkspace.didUnmountNotification,
           let unmountedURL = notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL {
            let unmountedPath = unmountedURL.standardizedFileURL.path
            let trimmedSource = sourcePath.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedSource.isEmpty {
                let standardizedSource = URL(fileURLWithPath: trimmedSource).standardizedFileURL.path
                let prefix = unmountedPath == "/" ? "/" : unmountedPath + "/"
                if standardizedSource == unmountedPath || standardizedSource.hasPrefix(prefix) {
                    bookmarkStore.stopAccess(for: .source)
                    sourcePath = ""
                }
            }
        }

        transferSettingsStore.updateDestinationPath(destinationPath)
        applySuggestedSourceIfNeeded()
    }

    func applySuggestedSourceIfNeeded() {
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

    func applySuggestedDestinationIfNeeded() {
        guard !isRunning else {
            return
        }

        let trimmedDestinationPath = destinationPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedDestinationPath.isEmpty else {
            return
        }

        if let bookmarkedURL = bookmarkStore.restoreDestinationBookmark() {
            destinationPath = bookmarkedURL.path
            return
        }

        guard let suggestedDestinationPath = destinationDefaulting.suggestedDestinationPath(),
              !suggestedDestinationPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }

        destinationPath = suggestedDestinationPath
    }

    func rememberDestinationIfNeeded() {
        let trimmedDestinationPath = destinationPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedDestinationPath.isEmpty else {
            return
        }

        destinationRemembering.saveLastDestinationPath(trimmedDestinationPath)
    }

    func scheduleSourceScanIfNeeded() {
        sourceScanTask?.cancel()

        let trimmedSourcePath = sourcePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSourcePath.isEmpty else {
            sourceScanState = .idle
            scannedPhotoCount = 0
            scannedVideoCount = 0
            scannedAudioCount = 0
            scannedTotalBytes = 0
            scannedFilesCheckedCount = 0
            scannedCheckedBytes = 0
            lastPreviewSummary = nil
            previewMetadataCache = nil
            return
        }

        guard LauncherPathValidation.isValidSourcePath(trimmedSourcePath) else {
            sourceScanState = .failed("Source must be a readable folder.")
            scannedPhotoCount = 0
            scannedVideoCount = 0
            scannedAudioCount = 0
            scannedTotalBytes = 0
            scannedFilesCheckedCount = 0
            scannedCheckedBytes = 0
            lastPreviewSummary = nil
            previewMetadataCache = nil
            return
        }

        sourceScanState = .scanning(nil)
        scannedPhotoCount = 0
        scannedVideoCount = 0
        scannedAudioCount = 0
        scannedTotalBytes = 0
        scannedFilesCheckedCount = 0
        scannedCheckedBytes = 0
        lastPreviewSummary = nil

        let newMetadataCache = InMemorySourceScanMetadataCache()
        previewMetadataCache = newMetadataCache

        sourceScanTask = Task { [weak self] in
            guard let self else {
                return
            }

            let scanner = sourceScanner
            let result = await Task.detached(priority: .utility) {
                Result {
                    try scanner.scan(sourcePath: trimmedSourcePath, mode: .preview, metadataCache: newMetadataCache) { snapshot in
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
                            self.scannedAudioCount = summary.audioCount
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
                scannedAudioCount = launcherSummary.audioCount
                scannedTotalBytes = launcherSummary.totalBytes
                scannedFilesCheckedCount = max(scannedFilesCheckedCount, preparation.scanSummary.candidates.count)
                scannedCheckedBytes = max(scannedCheckedBytes, launcherSummary.totalBytes)
                lastPreviewSummary = launcherSummary
                scheduleDestinationSpaceCheckIfNeeded()
            case .failure(let error):
                lastPreviewSummary = nil
                previewMetadataCache = nil
                if let scopeError = error as? SourceScannerError {
                    switch scopeError {
                    case .unreadableSourceRoot:
                        sourceScanState = .failed("Source must be a readable folder.")
                    case .sourceBoundaryViolation:
                        sourceScanState = .failed("Source scan blocked out-of-bound content.")
                    }
                } else {
                    sourceScanState = .failed("Source scan failed.")
                }
                scheduleDestinationSpaceCheckIfNeeded()
            }
        }
    }

    func scheduleDestinationSpaceCheckIfNeeded() {
        destinationSpaceCheckTask?.cancel()

        guard case .ready(let summary) = sourceScanState else {
            destinationSpaceState = .unchecked
            return
        }

        let trimmedDestinationPath = destinationPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard LauncherPathValidation.isValidDestinationPath(trimmedDestinationPath) else {
            destinationSpaceState = .unchecked
            return
        }

        destinationSpaceState = .unchecked
        let bytesToCopy = summary.totalBytes
        let destinationURL = URL(fileURLWithPath: trimmedDestinationPath, isDirectory: true)

        destinationSpaceCheckTask = Task { [weak self] in
            guard let self else {
                return
            }

            let outcome = await Task.detached(priority: .utility) {
                DestinationSpaceChecker.check(destinationURL: destinationURL, bytesToCopy: bytesToCopy)
            }.value

            guard !Task.isCancelled,
                  self.destinationPath.trimmingCharacters(in: .whitespacesAndNewlines) == trimmedDestinationPath,
                  case .ready(let currentSummary) = self.sourceScanState,
                  currentSummary.totalBytes == bytesToCopy else {
                return
            }

            self.destinationSpaceState = LauncherDestinationSpaceState(outcome: outcome)
        }
    }

    func acceptDestinationSpaceOverride() {
        if case let .insufficient(details, overrideAccepted: false) = destinationSpaceState {
            destinationSpaceState = .insufficient(details, overrideAccepted: true)
        }
    }

    var preferredReceiptOpenPath: String? {
        let fileManager = FileManager.default
        if !pdfSummaryPath.isEmpty, fileManager.fileExists(atPath: pdfSummaryPath) {
            return pdfSummaryPath
        }
        if !receiptPath.isEmpty, fileManager.fileExists(atPath: receiptPath) {
            return receiptPath
        }
        return nil
    }

    /// The source panel never offers "New Folder". A new folder on the card would change the card (I-1).
    static func makeSourcePanel() -> NSOpenPanel {
        makeDirectoryPanel(title: "Select Source Folder", prompt: "Use Source", canCreateDirectories: false)
    }

    static func makeDestinationPanel() -> NSOpenPanel {
        makeDirectoryPanel(title: "Select Destination Folder", prompt: "Use Destination", canCreateDirectories: true)
    }

    private static func makeDirectoryPanel(title: String, prompt: String, canCreateDirectories: Bool) -> NSOpenPanel {
        let panel = NSOpenPanel()
        panel.title = title
        panel.prompt = prompt
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = canCreateDirectories
        return panel
    }

    private func runDirectoryPanel(_ panel: NSOpenPanel) -> URL? {
        let response = panel.runModal()
        guard response == .OK else {
            return nil
        }

        return panel.url
    }
}
