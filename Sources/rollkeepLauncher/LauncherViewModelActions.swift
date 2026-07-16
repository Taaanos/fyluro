import AppKit
import Foundation
import RollKeepCore

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

    func handlePathInputChanged(sourceChanged: Bool) {
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
                    sourceScanState = .failed("Source scan failed. You can still start import.")
                }
            }
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
