import Foundation
import FyluroCore
import FyluroEngine

extension LauncherViewModel {
    func startIngest() {
        guard canStart else {
            handlePathInputChanged(sourceChanged: false)
            if statusMessage == "Import ready" {
                statusMessage = "Choose a readable source and writable destination first."
            }
            return
        }

        sourceScanTask?.cancel()
        resetRunState()
        seedRunCountersFromPreviewSummary()

        latestCorePhase = .scan
        currentPhase = .scan
        uiState = .running
        statusMessage = "Preparing import..."
        runStartedAt = Date()
        lastProgressEventAt = runStartedAt

        let request = ingestRequest()
        appendOutput("[system] Starting in-process ingest: \(sourcePath) -> \(destinationPath)")

        let handle = ingestRunnerFactory(request, previewMetadataCache)
        activeRun = handle

        ingestTask = Task { [weak self] in
            for await event in handle.events {
                self?.apply(event)
            }
            await self?.finishRunIfNeeded()
        }
    }

    func stopIngest() {
        guard isRunning, let activeRun else {
            return
        }

        stopRequestedByUser = true
        statusMessage = "Stopping import..."
        appendOutput("[system] Stop requested by user.")
        activeRun.cancel()
    }

    /// Builds the fully-resolved engine request from the current UI state. The
    /// app always runs a real (non-dry-run) ingest with a PDF summary.
    func ingestRequest() -> IngestRequest {
        let configuration = pathSchemeSettingsStore.appliedConfiguration
        let maxParallelCopies = transferSettingsStore.resolvedMaxParallelCopiesForRun(
            destinationPath: destinationPath
        )
        return IngestRequest(
            sourceURL: URL(fileURLWithPath: sourcePath, isDirectory: true),
            destinationURL: URL(fileURLWithPath: destinationPath, isDirectory: true),
            sourceResolution: "explicit",
            destinationResolution: "explicit",
            pathScheme: configuration.corePathScheme,
            dryRun: false,
            writePDF: true,
            maxParallelCopies: maxParallelCopies,
            jsonSummaryRequested: false,
            detectTimeoutSeconds: 60,
            pickSource: false,
            pickDestination: false,
            filmModeOverride: filmModeEnabled ? filmModeConfiguration : nil,
            useCameraCatalog: cameraLabelsPreference.isEnabled
        )
    }

    func apply(_ event: IngestEvent) {
        switch event {
        case let .sessionStarted(_, receiptPath, _):
            if !receiptPath.isEmpty {
                self.receiptPath = receiptPath
            }

        case let .phaseChanged(phase):
            applyReceiptUpdate(ParsedReceiptUpdate(phase: LauncherPhase.fromReceiptPhase(phase.rawValue)))

        case let .scanProgress(filesChecked, bytesChecked, candidates, photos, photoBytes, videos, videoBytes, audios, audioBytes, currentPath):
            applyReceiptUpdate(ParsedReceiptUpdate(
                phase: .scan,
                scannedCandidateCount: candidates,
                scannedFilesCheckedCount: filesChecked,
                scannedCheckedBytes: bytesChecked,
                scanPhotoCount: photos,
                scanVideoCount: videos,
                scanAudioCount: audios,
                scanPhotoBytes: photoBytes,
                scanVideoBytes: videoBytes,
                scanAudioBytes: audioBytes,
                currentFilePath: currentPath
            ))

        case let .scanCompleted(candidates, photos, photoBytes, videos, videoBytes, audios, audioBytes):
            applyReceiptUpdate(ParsedReceiptUpdate(
                scannedCandidateCount: candidates,
                scanPhotoCount: photos,
                scanVideoCount: videos,
                scanAudioCount: audios,
                scanPhotoBytes: photoBytes,
                scanVideoBytes: videoBytes,
                scanAudioBytes: audioBytes
            ))

        case let .planCompleted(plannedStageAndCommit, duplicatesSkipped, _, bytesToCopy, directoriesToCreate):
            self.bytesToCopy = bytesToCopy
            createdDirectories = directoriesToCreate
            applyReceiptUpdate(ParsedReceiptUpdate(
                plannedStageAndCommit: plannedStageAndCommit,
                duplicateNotCopied: duplicatesSkipped
            ))

        case let .fileCopyStarted(path, _):
            applyReceiptUpdate(ParsedReceiptUpdate(phase: .copy, copiedIncrement: 1, currentFilePath: path))

        case let .fileCopyProgress(path, bytesCopied, _):
            copiedBytesByPath[path] = bytesCopied
            markProgressEvent()
            updateRunningStatus()

        case let .fileVerifyProgress(path, bytesVerified, _):
            verifiedBytesByPath[path] = bytesVerified
            applyReceiptUpdate(ParsedReceiptUpdate(phase: .verify, currentFilePath: path))

        case let .fileVerified(path):
            applyReceiptUpdate(ParsedReceiptUpdate(phase: .verify, verifiedIncrement: 1, currentFilePath: path))

        case let .fileCommitted(_, finalPath):
            applyReceiptUpdate(ParsedReceiptUpdate(phase: .commit, committedIncrement: 1, currentFilePath: finalPath))

        case let .duplicateSkipped(path):
            applyReceiptUpdate(ParsedReceiptUpdate(phase: .commit, currentFilePath: path))

        case let .receiptLineAppended(line):
            appendReceiptLine(line)

        case let .errorRecorded(phase, message, paths):
            let item = ReceiptErrorItem(
                eventIndex: seenErrorEventIndexes.count + 1,
                phase: LauncherPhase.fromReceiptPhase(phase.rawValue),
                message: message,
                paths: paths
            )
            applyReceiptUpdate(ParsedReceiptUpdate(errorItem: item))

        case let .finished(result):
            applyFinished(result)
        }
    }

    private func applyFinished(_ result: IngestSessionResult) {
        sawFinishedEvent = true

        if !result.receiptPath.isEmpty {
            receiptPath = result.receiptPath
        }
        if let pdf = result.pdfSummaryPath, !pdf.isEmpty {
            updatePDFSummaryPath(pdf)
        }
        if stagingPath.isEmpty {
            stagingPath = result.stagingSessionPath
        }

        finalizedCommittedCount = max(0, result.counts.committed)
        finalizedDuplicateNotCopiedCount = max(0, result.counts.duplicateNotCopied)
        finalizedFilmModeExifSkippedCount = max(0, result.filmModeExifSkipped)
        finalizedPhotoCount = max(0, result.counts.photos)
        finalizedVideoCount = max(0, result.counts.videos)
        finalizedAudioCount = max(0, result.counts.audios)
        finalizedConflictsRenamedCount = max(0, result.counts.conflictsRenamed)
        idempotentRerunDetected = result.idempotency.classification == "idempotent_rerun"

        let totalMs = result.phaseTimings.reduce(0) { $0 + $1.milliseconds }
        if totalMs > 0 {
            finalizedTotalDurationMs = totalMs
        }

        if result.finalStatus == "aborted", failureReason.isEmpty, let reason = result.failureReason {
            failureReason = reason
        }

        parsedResult = result.finalStatus == "aborted" ? .failure : .success
    }

    /// Finalizes UI state once the event stream ends. Mirrors the old process
    /// termination handler: resolves success/failure and the stop message.
    @MainActor
    func finishRunIfNeeded() {
        guard uiState == .running else {
            return
        }

        let finishedAt = Date()
        let result = parsedResult ?? (sawFinishedEvent ? .success : .failure)
        uiState = result == .success ? .success : .failure
        currentPhase = .finished
        activeRun = nil

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
                statusMessage = shortFailureSummary()
            }
        }
    }

    func resetRunState() {
        parsedResult = nil
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
        finalizedFilmModeExifSkippedCount = 0
        finalizedPhotoCount = 0
        finalizedVideoCount = 0
        finalizedAudioCount = 0
        finalizedConflictsRenamedCount = 0
        finalizedTotalDurationMs = nil
        idempotentRerunDetected = false
        scannedPhotoCount = 0
        scannedVideoCount = 0
        scannedAudioCount = 0
        scannedTotalBytes = 0
        scannedFilesCheckedCount = 0
        scannedCheckedBytes = 0
        receiptErrors = []
        touchedPaths = []
        createdDirectories = []
        seenErrorEventIndexes = []
        bytesToCopy = 0
        copiedBytesByPath = [:]
        verifiedBytesByPath = [:]
        sawFinishedEvent = false
        runStartedAt = nil
        lastProgressEventAt = nil
        progressCounters = LauncherProgressCounters()
        stopRequestedByUser = false
        wasStoppedByUser = false
        activeRun = nil
        ingestTask?.cancel()
        ingestTask = nil
    }

    func seedRunCountersFromPreviewSummary() {
        guard let summary = lastPreviewSummary else {
            return
        }

        scannedCandidateCount = max(scannedCandidateCount, summary.itemCount)
        scannedPhotoCount = max(scannedPhotoCount, summary.photoCount)
        scannedVideoCount = max(scannedVideoCount, summary.videoCount)
        scannedAudioCount = max(scannedAudioCount, summary.audioCount)
        scannedTotalBytes = max(scannedTotalBytes, summary.totalBytes)
        scannedFilesCheckedCount = max(scannedFilesCheckedCount, summary.itemCount)
        scannedCheckedBytes = max(scannedCheckedBytes, summary.totalBytes)
    }

    private func shortFailureSummary() -> String {
        if !failureReason.isEmpty {
            return "Failed: \(truncated(failureReason, limit: 140))"
        }
        return "Failed."
    }

    private func truncated(_ text: String, limit: Int) -> String {
        guard text.count > limit else {
            return text
        }

        let endIndex = text.index(text.startIndex, offsetBy: limit)
        return "\(text[text.startIndex..<endIndex])..."
    }
}
