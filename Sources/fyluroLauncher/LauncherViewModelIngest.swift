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
        runState = .running(stopRequested: false)
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
        startThroughputTicker()
    }

    func stopIngest() {
        guard case .running(stopRequested: false) = runState, let activeRun else {
            return
        }

        runState = .running(stopRequested: true)
        statusMessage = "Stopping import..."
        appendOutput("[system] Stop requested by user.")
        activeRun.cancel()
    }

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
            filmModeOverride: filmModeState.configuration,
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
            let launcherPhase = LauncherPhase.fromReceiptPhase(phase.rawValue)
            if let launcherPhase {
                throughputTracker.enterPhase(launcherPhase, at: Date())
            }
            applyReceiptUpdate(ParsedReceiptUpdate(phase: launcherPhase))

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
            throughputTracker.enterPhase(.copy, at: Date())
            applyReceiptUpdate(ParsedReceiptUpdate(phase: .copy, copiedIncrement: 1, currentFilePath: path))

        case let .fileCopyProgress(path, bytesCopied, _):
            let previous = copiedBytesByPath[path] ?? 0
            if bytesCopied > previous {
                copiedBytesByPath[path] = bytesCopied
                totalCopiedBytes += (bytesCopied - previous)
            }
            throughputTracker.recordCopiedBytes(totalCopiedBytes, at: Date())
            markProgressEvent()
            updateRunningStatus()

        case let .fileVerifyProgress(path, bytesVerified, _):
            let previous = verifiedBytesByPath[path] ?? 0
            if bytesVerified > previous {
                verifiedBytesByPath[path] = bytesVerified
                totalVerifiedBytes += (bytesVerified - previous)
            }
            throughputTracker.recordVerifiedBytes(totalVerifiedBytes, at: Date())
            applyReceiptUpdate(ParsedReceiptUpdate(phase: .verify, currentFilePath: path))

        case let .fileVerified(path):
            applyReceiptUpdate(ParsedReceiptUpdate(phase: .verify, verifiedIncrement: 1, currentFilePath: path))

        case let .fileCommitted(_, finalPath):
            throughputTracker.enterPhase(.commit, at: Date())
            applyReceiptUpdate(ParsedReceiptUpdate(phase: .commit, committedIncrement: 1, currentFilePath: finalPath))

        case let .duplicateSkipped(path):
            throughputTracker.enterPhase(.commit, at: Date())
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

        let totalMs = result.phaseTimings.reduce(0) { $0 + $1.milliseconds }
        if totalMs > 0 {
            finalizedTotalDurationMs = totalMs
        }

        let copyDurationMs = result.phaseTimings.first(where: { $0.phase == .copy })?.milliseconds
        let verifyDurationMs = result.phaseTimings.first(where: { $0.phase == .verify })?.milliseconds
        throughputTracker.finalize(
            at: Date(),
            copyDurationMs: copyDurationMs,
            verifyDurationMs: verifyDurationMs
        )

        if result.finalStatus == "aborted", failureReason.isEmpty, let reason = result.failureReason {
            failureReason = reason
        }

        parsedResult = result.finalStatus == "aborted"
            ? .failure
            : .success(idempotentRerun: result.idempotency.classification == "idempotent_rerun")
    }

    @MainActor
    func finishRunIfNeeded() {
        guard case let .running(userRequestedStop) = runState else {
            return
        }

        let finishedAt = Date()
        stopThroughputTicker()
        throughputTracker.finalize(at: finishedAt)
        let result = parsedResult ?? (sawFinishedEvent ? .success(idempotentRerun: parsedIdempotentRerun) : .failure)
        switch result {
        case .success(let idempotentRerun):
            runState = .succeeded(idempotentRerun: idempotentRerun)
        case .failure:
            runState = .failed(stoppedByUser: userRequestedStop)
        }
        currentPhase = .finished
        activeRun = nil

        if finalizedTotalDurationMs == nil, let runStartedAt {
            let elapsedMs = Int((finishedAt.timeIntervalSince(runStartedAt) * 1_000).rounded())
            finalizedTotalDurationMs = max(0, elapsedMs)
        }

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
        parsedIdempotentRerun = false
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
        totalCopiedBytes = 0
        totalVerifiedBytes = 0
        throughputTracker.reset()
        stopThroughputTicker()
        sawFinishedEvent = false
        runStartedAt = nil
        lastProgressEventAt = nil
        progressCounters = LauncherProgressCounters()
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

    private func startThroughputTicker() {
        stopThroughputTicker()
        throughputTickTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self, self.isRunning else {
                    break
                }
                self.throughputTracker.recordTick(at: Date())
            }
        }
    }

    private func stopThroughputTicker() {
        throughputTickTask?.cancel()
        throughputTickTask = nil
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
