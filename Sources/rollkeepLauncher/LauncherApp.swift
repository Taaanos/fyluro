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

@MainActor
final class LauncherViewModel: ObservableObject {
    @Published var sourcePath = "" {
        didSet {
            handlePathInputChanged()
        }
    }
    @Published var destinationPath = "" {
        didSet {
            handlePathInputChanged()
        }
    }
    @Published var outputText = ""
    @Published var receiptPreviewText = ""
    @Published var currentPhase: LauncherPhase = .idle
    @Published var uiState: LauncherUIState = .idle
    @Published var statusMessage = "Select source and destination to start ingest."
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
    @Published var receiptErrors: [ReceiptErrorItem] = []
    @Published var touchedPaths: [String] = []

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
    private var runStartedAt: Date?

    deinit {
        receiptPollTimer?.invalidate()
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

    var shouldShowReceiptAction: Bool {
        uiState == .success || uiState == .failure
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
            statusMessage = "Select a readable source and writable destination first."
            return
        }

        guard let cliExecutable = RollkeepCLIExecutableLocator.resolve() else {
            uiState = .failure
            currentPhase = .finished
            statusMessage = "Failed to find rollkeep CLI executable."
            appendOutput("[system] Could not locate `rollkeep`. Set ROLLKEEP_CLI_PATH or place rollkeep in PATH.")
            return
        }

        resetRunState()
        latestCorePhase = .scan
        currentPhase = .scan
        uiState = .running
        statusMessage = "Running scan..."
        stopReceiptPolling()
        runStartedAt = Date()
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
            statusMessage = "Failed to launch rollkeep process."
            appendOutput("[system] Failed to run process: \(error.localizedDescription)")
        }
    }

    func openReceipt() {
        guard canOpenReceipt else {
            statusMessage = "Receipt file is not available."
            return
        }

        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: receiptPath)])
    }

    func openStagingFolder() {
        guard canOpenStagingFolder else {
            statusMessage = "Staging folder is not available."
            return
        }

        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: stagingPath)])
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
    }

    private func handlePathInputChanged() {
        guard !isRunning else {
            return
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
            statusMessage = "Select source and destination to start ingest."
        } else {
            statusMessage = "Select a readable source and writable destination."
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

        switch result {
        case .success:
            latestCorePhase = .finalize
            statusMessage = "Verified"
        case .failure:
            if failureReason.isEmpty, let receiptError = receiptErrors.first?.message {
                failureReason = receiptError
            }
            statusMessage = shortFailureSummary(exitCode: exitCode)
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

        if plannedStageAndCommitCount > 0 {
            switch latestCorePhase {
            case .plan:
                statusMessage = "Running plan for \(plannedStageAndCommitCount) files..."
            case .copy:
                statusMessage = "Running copy \(copiedCount)/\(plannedStageAndCommitCount) files..."
            case .verify:
                statusMessage = "Running verify \(verifiedCount)/\(plannedStageAndCommitCount) files..."
            case .commit:
                statusMessage = "Running commit \(committedCount)/\(plannedStageAndCommitCount) files..."
            case .finalize, .finished:
                statusMessage = "Finalizing ingest..."
            case .idle, .scan:
                statusMessage = "Running scan..."
            }
            return
        }

        switch latestCorePhase {
        case .finished:
            statusMessage = "Finishing ingest..."
        case .finalize:
            statusMessage = "Finalizing ingest..."
        case .idle:
            statusMessage = "Starting ingest..."
        case .scan where scannedCandidateCount > 0:
            statusMessage = "Running scan... \(scannedCandidateCount) files found so far."
        case .plan where scannedCandidateCount > 0:
            statusMessage = "Running plan for \(scannedCandidateCount) files..."
        default:
            statusMessage = "Running \(latestCorePhase.displayName.lowercased())..."
        }
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
        }
        if let scanned = update.scannedCandidateCount {
            scannedCandidateCount = max(scannedCandidateCount, scanned)
        }

        if let planned = update.plannedStageAndCommit {
            plannedStageAndCommitCount = max(plannedStageAndCommitCount, planned)
        }
        if let duplicates = update.duplicateNotCopied {
            duplicateNotCopiedCount = max(duplicateNotCopiedCount, duplicates)
        }

        copiedCount += update.copiedIncrement
        verifiedCount += update.verifiedIncrement
        committedCount += update.committedIncrement

        if plannedStageAndCommitCount > 0 {
            copiedCount = min(copiedCount, plannedStageAndCommitCount)
            verifiedCount = min(verifiedCount, plannedStageAndCommitCount)
            committedCount = min(committedCount, plannedStageAndCommitCount)
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

struct LauncherPathRow: View {
    let title: String
    @Binding var path: String
    let isEnabled: Bool
    let browseAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.headline)

            HStack(spacing: 8) {
                TextField("Select a folder", text: $path)
                    .textFieldStyle(.roundedBorder)
                Button("Browse", action: browseAction)
            }
            .disabled(!isEnabled)
        }
    }
}

struct LauncherDetailsSection: View {
    @ObservedObject var viewModel: LauncherViewModel

    var body: some View {
        DisclosureGroup("Details", isExpanded: $viewModel.isDetailsExpanded) {
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

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LauncherPathRow(
                title: "Source",
                path: $viewModel.sourcePath,
                isEnabled: !viewModel.isRunning,
                browseAction: viewModel.pickSourcePath
            )

            LauncherPathRow(
                title: "Destination",
                path: $viewModel.destinationPath,
                isEnabled: !viewModel.isRunning,
                browseAction: viewModel.pickDestinationPath
            )

            HStack {
                Button("Start Ingest", action: viewModel.startIngest)
                    .disabled(!viewModel.canStart)
                Spacer()
            }

            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(viewModel.statusMessage)
                    .foregroundStyle(viewModel.statusColor)
                    .lineLimit(2)
                Spacer(minLength: 8)
                if viewModel.shouldShowReceiptAction && viewModel.canOpenReceipt {
                    Button("Reveal Receipt in Finder", action: viewModel.openReceipt)
                }
            }

            LauncherDetailsSection(viewModel: viewModel)
        }
        .padding(16)
        .frame(minWidth: 620, idealWidth: 640, minHeight: 320, idealHeight: 360)
    }
}

@main
struct RollkeepLauncherApp: App {
    var body: some Scene {
        WindowGroup {
            LauncherContentView()
        }
    }
}
