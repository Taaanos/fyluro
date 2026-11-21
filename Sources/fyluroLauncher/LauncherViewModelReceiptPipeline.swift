import Foundation

extension LauncherViewModel {
    func updateRunningStatus() {
        guard uiState == .running else {
            return
        }

        statusMessage = "\(importingPhaseDescription)."
    }

    func updatePDFSummaryPath(_ path: String) {
        guard !path.isEmpty else {
            return
        }
        pdfSummaryPath = path
    }

    func applyReceiptUpdate(_ update: ParsedReceiptUpdate) {
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
        if let audioCount = update.scanAudioCount {
            scannedAudioCount = max(scannedAudioCount, audioCount)
        }
        if update.scanPhotoBytes != nil || update.scanVideoBytes != nil || update.scanAudioBytes != nil {
            let combinedBytes = (update.scanPhotoBytes ?? 0) + (update.scanVideoBytes ?? 0) + (update.scanAudioBytes ?? 0)
            scannedTotalBytes = max(scannedTotalBytes, combinedBytes)
        }

        if let scanned = update.scannedCandidateCount,
           update.scanPhotoCount != nil || update.scanVideoCount != nil || update.scanAudioCount != nil {
            let summary = LauncherSourceScopeSummary(
                itemCount: scanned,
                photoCount: update.scanPhotoCount ?? scannedPhotoCount,
                videoCount: update.scanVideoCount ?? scannedVideoCount,
                audioCount: update.scanAudioCount ?? scannedAudioCount,
                totalBytes: (update.scanPhotoBytes ?? 0) + (update.scanVideoBytes ?? 0) + (update.scanAudioBytes ?? 0)
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
            parsedIdempotentRerun = idempotent
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

    func syncProgressCountersToPublished() {
        scannedCandidateCount = progressCounters.scannedCandidateCount
        plannedStageAndCommitCount = progressCounters.plannedStageAndCommitCount
        duplicateNotCopiedCount = progressCounters.duplicateNotCopiedCount
        copiedCount = progressCounters.copiedCount
        verifiedCount = progressCounters.verifiedCount
        committedCount = progressCounters.committedCount
    }

    func markProgressEvent() {
        lastProgressEventAt = Date()
    }

#if DEBUG
    func applyReceiptUpdateForTesting(_ update: ParsedReceiptUpdate) {
        applyReceiptUpdate(update)
    }
#endif

    func appendOutput(_ line: String) {
        if outputText.isEmpty {
            outputText = line
        } else {
            outputText.append("\n")
            outputText.append(line)
        }
    }

    func appendReceiptLine(_ line: String) {
        receiptPreviewLines.append(line)
        if receiptPreviewLines.count > 240 {
            receiptPreviewLines.removeFirst(receiptPreviewLines.count - 240)
        }
        receiptPreviewText = receiptPreviewLines.joined(separator: "\n")
    }

    func inferStagingSessionPath(from paths: [String]) -> String? {
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
}
