import AppKit
import Foundation
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
    case scanning
    case ready(LauncherSourceScopeSummary)
    case failed(String)
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
    @Published var isDetailsExpanded = false
    @Published var scannedCandidateCount = 0
    @Published var plannedStageAndCommitCount = 0
    @Published var duplicateNotCopiedCount = 0
    @Published var copiedCount = 0
    @Published var verifiedCount = 0
    @Published var committedCount = 0
    @Published var scannedPhotoCount = 0
    @Published var scannedVideoCount = 0
    @Published var scannedTotalBytes: Int64 = 0
    @Published var receiptErrors: [ReceiptErrorItem] = []
    @Published var touchedPaths: [String] = []
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

    private var activeProcess: Process?
    private var parser = CLIOutputParser()
    private var receiptParser = ReceiptEventParser()
    private var stdoutCarry = ""
    private var stderrCarry = ""
    private var receiptCarry = ""
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

    var canStart: Bool {
        !isRunning && sourcePathValid && destinationPathValid
    }

    var isRunning: Bool {
        uiState == .running
    }

    var canOpenReceipt: Bool {
        !receiptPath.isEmpty && FileManager.default.fileExists(atPath: receiptPath)
    }

    var canOpenStagingFolder: Bool {
        !stagingPath.isEmpty && FileManager.default.fileExists(atPath: stagingPath)
    }

    var canOpenDestination: Bool {
        destinationPathValid
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
            return "Select a source to preview item count and size."
        case .scanning:
            return "Scanning source media..."
        case .ready(let summary):
            return "\(summary.itemCount) items \u{2022} \(formattedBytes(summary.totalBytes)) \u{2022} \(summary.mediaDescription)"
        case .failed(let message):
            return message
        }
    }

    var isSourceScanning: Bool {
        if case .scanning = sourceScanState {
            return true
        }
        return false
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
            progressFraction: importingProgressFraction
        )
    }

    var completionItemsText: String {
        let imported = committedCount
        return imported == 1 ? "1 item imported" : "\(imported) items imported"
    }

    var completionReceiptText: String {
        receiptPath.isEmpty ? "Receipt path unavailable" : "Receipt saved"
    }

    var failureTitle: String {
        wasStoppedByUser ? "Import Stopped" : "Import Needs Attention"
    }

    var failureMessage: String {
        if !failureReason.isEmpty {
            return failureReason
        }
        return "The import did not finish. Technical details are available below."
    }

    var detailsDisclosureTitle: String {
        isDetailsExpanded ? "Hide Technical Details" : "Show Technical Details"
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
            statusMessage = "Choose a readable source and writable destination first."
            return
        }

        guard let cliExecutable = RollkeepCLIExecutableLocator.resolve() else {
            uiState = .failure
            currentPhase = .finished
            statusMessage = "RollKeep CLI executable was not found."
            appendOutput("[system] Could not locate `rollkeep`. Set ROLLKEEP_CLI_PATH or place rollkeep in PATH.")
            return
        }

        sourceScanTask?.cancel()
        resetRunState()

        latestCorePhase = .scan
        currentPhase = .scan
        uiState = .running
        statusMessage = "Preparing import..."
        stopReceiptPolling()
        runStartedAt = Date()
        lastProgressEventAt = runStartedAt
        ensureReceiptPollingTimer()

        let process = Process()
        process.executableURL = cliExecutable
        process.arguments = ["--source", sourcePath, "--dest", destinationPath]
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

        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: receiptPath)])
    }

    func openDestination() {
        guard canOpenDestination else {
            statusMessage = "Destination folder is not available."
            return
        }

        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: destinationPath)])
    }

    func openStagingFolder() {
        guard canOpenStagingFolder else {
            statusMessage = "Staging folder is not available."
            return
        }

        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: stagingPath)])
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
    }

    private func resetRunState() {
        parser = CLIOutputParser()
        receiptParser = ReceiptEventParser()
        parsedResult = nil
        stdoutCarry = ""
        stderrCarry = ""
        receiptCarry = ""
        receiptPath = ""
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
        receiptErrors = []
        touchedPaths = []
        seenErrorEventIndexes = []
        monitoredReceiptPath = ""
        receiptReadOffset = 0
        isDetailsExpanded = false
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
            uiState = .ready
            statusMessage = "Ready to ingest."
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

        statusMessage = "Choose a readable source and writable destination."
    }

    private func scheduleSourceScanIfNeeded() {
        sourceScanTask?.cancel()

        let trimmedSourcePath = sourcePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSourcePath.isEmpty else {
            sourceScanState = .idle
            scannedPhotoCount = 0
            scannedVideoCount = 0
            scannedTotalBytes = 0
            return
        }

        guard LauncherPathValidation.isValidSourcePath(trimmedSourcePath) else {
            sourceScanState = .failed("Source must be a readable folder.")
            scannedPhotoCount = 0
            scannedVideoCount = 0
            scannedTotalBytes = 0
            return
        }

        sourceScanState = .scanning

        sourceScanTask = Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                Result { try LauncherSourceScopeScanner().scan(sourcePath: trimmedSourcePath) }
            }.value

            guard let self else {
                return
            }

            guard !Task.isCancelled,
                  self.sourcePath.trimmingCharacters(in: .whitespacesAndNewlines) == trimmedSourcePath else {
                return
            }

            switch result {
            case .success(let summary):
                sourceScanState = .ready(summary)
                scannedPhotoCount = summary.photoCount
                scannedVideoCount = summary.videoCount
                scannedTotalBytes = summary.totalBytes
            case .failure(let error):
                if let scopeError = error as? LauncherSourceScopeError {
                    switch scopeError {
                    case .unreadableSourceRoot:
                        sourceScanState = .failed("Source must be a readable folder.")
                    }
                } else {
                    sourceScanState = .failed("Source scan failed. You can still start import.")
                }
            }
        }
    }

    private func handleTermination(process: Process, stdoutPipe: Pipe, stderrPipe: Pipe) {
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

        let userRequestedStop = stopRequestedByUser
        stopRequestedByUser = false
        wasStoppedByUser = userRequestedStop

        switch result {
        case .success:
            latestCorePhase = .finalize
            statusMessage = "Import complete."
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
        if let stagePath = update.stagingPath, !stagePath.isEmpty {
            stagingPath = stagePath
        }
        if let reason = update.failureReason, !reason.isEmpty {
            failureReason = reason
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

        updateRunningStatus()
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
        "\(shellQuoted(executablePath)) --source \(shellQuoted(sourcePath)) --dest \(shellQuoted(destinationPath))"
    }

    private func shellQuoted(_ value: String) -> String {
        guard !value.isEmpty else {
            return "''"
        }

        let escaped = value.replacingOccurrences(of: "'", with: "'\\''")
        return "'\(escaped)'"
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

private struct LauncherSelectionCard: View {
    let systemImage: String
    let title: String
    let subtitle: String
    let path: String
    let placeholder: String
    let buttonTitle: String
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 21, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                if path.isEmpty {
                    Text(placeholder)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    Text(path)
                        .font(.subheadline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 12)

            Button(buttonTitle, action: action)
                .buttonStyle(.bordered)
                .disabled(!isEnabled)
        }
        .padding(14)
        .background(cardBackground)
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color(nsColor: .controlBackgroundColor))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 0.6)
            )
    }
}

private struct LauncherTechnicalDetailsSection: View {
    @ObservedObject var viewModel: LauncherViewModel

    var body: some View {
        DisclosureGroup(isExpanded: $viewModel.isDetailsExpanded) {
            VStack(alignment: .leading, spacing: 10) {
                if !viewModel.executedCommand.isEmpty {
                    detailsValueBlock(title: "Executed Command", value: viewModel.executedCommand)
                }

                if !viewModel.receiptPath.isEmpty {
                    detailsValueBlock(title: "Receipt Path", value: viewModel.receiptPath)
                }

                if !viewModel.stagingPath.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Staging Path")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 8)
                            Button("Reveal Staging in Finder", action: viewModel.openStagingFolder)
                                .disabled(!viewModel.canOpenStagingFolder)
                        }

                        Text(viewModel.stagingPath)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                }

                if viewModel.plannedStageAndCommitCount > 0 || viewModel.duplicateNotCopiedCount > 0 {
                    Text("Planned stage+commit: \(viewModel.plannedStageAndCommitCount), duplicates skipped: \(viewModel.duplicateNotCopiedCount)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if !viewModel.receiptErrors.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Errors")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        ScrollView {
                            Text(viewModel.receiptErrors.map { error in
                                let phase = error.phase?.displayName ?? "Unknown"
                                if error.paths.isEmpty {
                                    return "[\(phase)] \(error.message)"
                                }
                                return "[\(phase)] \(error.message)\n\(error.paths.joined(separator: "\n"))"
                            }.joined(separator: "\n\n"))
                                .frame(maxWidth: .infinity, alignment: .topLeading)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                                .padding(8)
                        }
                        .frame(maxHeight: 130)
                        .background(Color(nsColor: .textBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                }

                if !viewModel.touchedPaths.isEmpty {
                    detailsScrollableTextBlock(
                        title: "Touched Paths",
                        value: viewModel.touchedPaths.joined(separator: "\n"),
                        maxHeight: 110
                    )
                }

                detailsScrollableTextBlock(
                    title: "Live Receipt (NDJSON)",
                    value: viewModel.receiptPreviewText.isEmpty ? "Receipt events appear here as they are written." : viewModel.receiptPreviewText,
                    maxHeight: 140
                )

                detailsScrollableTextBlock(
                    title: "Command Output",
                    value: viewModel.outputText.isEmpty ? "Command output appears here." : viewModel.outputText,
                    maxHeight: 160
                )
            }
            .padding(.top, 8)
        } label: {
            Text(viewModel.detailsDisclosureTitle)
                .font(.subheadline.weight(.medium))
        }
    }

    @ViewBuilder
    private func detailsValueBlock(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.monospaced())
                .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private func detailsScrollableTextBlock(title: String, value: String, maxHeight: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)

            ScrollView {
                Text(value)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .padding(8)
            }
            .frame(maxHeight: maxHeight)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }
}

struct LauncherContentView: View {
    @StateObject private var viewModel = LauncherViewModel()
    @State private var configuredWindowID: ObjectIdentifier?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            headerSection

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

            LauncherTechnicalDetailsSection(viewModel: viewModel)
        }
        .padding(18)
        .frame(minWidth: 520, idealWidth: 560, minHeight: 360, idealHeight: 420, alignment: .topLeading)
        .background(
            LauncherWindowAccessor { window in
                configureWindowIfNeeded(window)
            }
        )
    }

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(headerTitle)
                .font(.title2.weight(.semibold))
            Text(headerSubtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var setupSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            LauncherSelectionCard(
                systemImage: "externaldrive",
                title: "Source",
                subtitle: "SD card, camera, or folder",
                path: viewModel.sourcePath,
                placeholder: "Select source media",
                buttonTitle: viewModel.sourcePath.isEmpty ? "Choose" : "Change",
                isEnabled: !viewModel.isRunning,
                action: viewModel.pickSourcePath
            )

            LauncherSelectionCard(
                systemImage: "folder",
                title: "Destination",
                subtitle: "Library destination",
                path: viewModel.destinationPath,
                placeholder: "Select destination library",
                buttonTitle: viewModel.destinationPath.isEmpty ? "Choose" : "Change",
                isEnabled: !viewModel.isRunning,
                action: viewModel.pickDestinationPath
            )

            HStack(spacing: 8) {
                if viewModel.isSourceScanning {
                    ProgressView()
                        .controlSize(.small)
                }
                Text(viewModel.setupScopeSummaryText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 2)

            Button("Start Import", action: viewModel.startIngest)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
                .disabled(!viewModel.canStart)

            Text(viewModel.statusMessage)
                .font(.footnote)
                .foregroundStyle(viewModel.statusColor)
        }
        .padding(16)
        .background(sectionBackground)
    }

    private var importingSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(viewModel.importingTitle)
                .font(.title3.weight(.semibold))

            ProgressView(value: viewModel.importingProgressFraction)
                .controlSize(.large)

            Text(viewModel.importingProgressText)
                .font(.body)

            Text(viewModel.importingETA)
                .font(.subheadline)
                .foregroundStyle(.secondary)

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
        .padding(16)
        .background(sectionBackground)
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
                    Text(viewModel.completionReceiptText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )

            Button("Open Destination", action: viewModel.openDestination)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
                .disabled(!viewModel.canOpenDestination)

            Button("View Receipt", action: viewModel.openReceipt)
                .buttonStyle(.bordered)
                .frame(maxWidth: .infinity)
                .disabled(!viewModel.canOpenReceipt)

            Button("Import Another Card", action: viewModel.importAnotherCard)
                .buttonStyle(.bordered)
                .frame(maxWidth: .infinity)
        }
        .padding(16)
        .background(sectionBackground)
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
        .padding(16)
        .background(sectionBackground)
    }

    private var headerTitle: String {
        switch viewModel.uiState {
        case .idle, .ready:
            return "RollKeep"
        case .running:
            return "Importing"
        case .success:
            return "Complete"
        case .failure:
            return "Import"
        }
    }

    private var headerSubtitle: String {
        switch viewModel.uiState {
        case .idle, .ready:
            return "Import from card to archive"
        case .running:
            return "Keep this window open while files are copied and verified."
        case .success:
            return "Your media has been safely transferred."
        case .failure:
            return "A human-readable summary is shown above. Technical details remain available below."
        }
    }

    private var sectionBackground: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(Color(nsColor: .windowBackgroundColor))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 0.8)
            )
    }

    private func configureWindowIfNeeded(_ window: NSWindow) {
        let id = ObjectIdentifier(window)
        guard configuredWindowID != id else {
            return
        }
        configuredWindowID = id

        window.minSize = NSSize(width: 520, height: 360)
        window.setContentSize(NSSize(width: 560, height: 420))
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
        .defaultSize(width: 560, height: 420)
        .windowResizability(.contentSize)
    }
}
