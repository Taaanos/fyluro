import Foundation

extension LauncherViewModel {
    func updateRunningStatus() {
        guard uiState == .running else {
            return
        }

        statusMessage = "\(importingPhaseDescription)."
    }

    func updateReceiptPath(_ path: String) {
        guard !path.isEmpty else {
            return
        }
        receiptPath = path
        startReceiptPolling(path: path)
    }

    func updatePDFSummaryPath(_ path: String) {
        guard !path.isEmpty else {
            return
        }
        pdfSummaryPath = path
    }

    func startReceiptPolling(path: String) {
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

    func stopReceiptPolling() {
        receiptPollTimer?.invalidate()
        receiptPollTimer = nil
    }

    func ensureReceiptPollingTimer() {
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

    func pollReceiptIfNeeded() {
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

    func consumeReceiptChunk(_ chunk: String) {
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

    func applyOutputUpdateForTesting(_ update: ParsedOutputUpdate) {
        applyParsedOutputUpdate(update)
    }
#endif

    func consume(chunk: String, stream: OutputStreamKind) {
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

    func flushPendingOutput(stream: OutputStreamKind) {
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

    func consumeCompleteLines(from buffer: inout String) -> [String] {
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

    func handleLine(_ line: String, stream: OutputStreamKind) {
        appendOutput("[\(stream.rawValue)] \(line)")

        let update = parser.parse(line: line)
        applyParsedOutputUpdate(update)
    }

    func applyParsedOutputUpdate(_ update: ParsedOutputUpdate) {
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
        if let scanned = update.scannedCandidateCount {
            scannedCandidateCount = max(scannedCandidateCount, scanned)
            scannedFilesCheckedCount = max(scannedFilesCheckedCount, scanned)
            scannedCheckedBytes = max(scannedCheckedBytes, scannedTotalBytes)

            if update.scanPhotoCount != nil || update.scanVideoCount != nil {
                let summary = LauncherSourceScopeSummary(
                    itemCount: scanned,
                    photoCount: update.scanPhotoCount ?? scannedPhotoCount,
                    videoCount: update.scanVideoCount ?? scannedVideoCount,
                    totalBytes: (update.scanPhotoBytes ?? 0) + (update.scanVideoBytes ?? 0)
                )
                sourceScanState = .ready(summary)
            }
        }
        if let result = update.result {
            parsedResult = result
        }
    }

    func appendOutput(_ line: String) {
        if outputText.isEmpty {
            outputText = line
        } else {
            outputText.append("\n")
            outputText.append(line)
        }
    }

    func commandLine(executablePath: String, arguments: [String]) -> String {
        ([shellQuoted(executablePath)] + arguments.map(shellQuoted(_:))).joined(separator: " ")
    }

    nonisolated static func ingestArguments(
        sourcePath: String,
        destinationPath: String,
        pathSchemeConfiguration: LauncherPathSchemeConfiguration
    ) -> [String] {
        var arguments = [
            "--source", sourcePath,
            "--dest", destinationPath,
            "--pdf",
            "--path-chronological", pathSchemeConfiguration.chronologicalLayout.rawValue,
        ]

        if !pathSchemeConfiguration.includeCameraFolder {
            arguments.append("--path-no-camera")
        }
        if pathSchemeConfiguration.splitPhotoCompression {
            arguments.append("--path-split-raw")
        }

        return arguments
    }

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

    private func shellQuoted(_ value: String) -> String {
        guard !value.isEmpty else {
            return "''"
        }

        let escaped = value.replacingOccurrences(of: "'", with: "'\\''")
        return "'\(escaped)'"
    }
}
