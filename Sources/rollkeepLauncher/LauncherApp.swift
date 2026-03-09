import AppKit
import Foundation
import SwiftUI

enum LauncherUIState {
    case idle
    case running
    case success
    case failure

    var label: String {
        switch self {
        case .idle:
            return "Idle"
        case .running:
            return "Running"
        case .success:
            return "Success"
        case .failure:
            return "Failure"
        }
    }
}

private enum OutputStreamKind: String {
    case stdout = "stdout"
    case stderr = "stderr"
}

enum LauncherPhaseVisualState {
    case pending
    case active
    case complete
    case failed

    var symbolName: String {
        switch self {
        case .pending:
            return "circle"
        case .active:
            return "arrow.triangle.2.circlepath.circle.fill"
        case .complete:
            return "checkmark.circle.fill"
        case .failed:
            return "xmark.octagon.fill"
        }
    }

    var color: Color {
        switch self {
        case .pending:
            return .secondary
        case .active:
            return .blue
        case .complete:
            return .green
        case .failed:
            return .red
        }
    }
}

struct LauncherPhaseRowSnapshot: Identifiable {
    let phase: LauncherPhase
    let visualState: LauncherPhaseVisualState
    let detail: String

    var id: String { phase.rawValue }
}

@MainActor
final class LauncherViewModel: ObservableObject {
    @Published var sourcePath = ""
    @Published var destinationPath = ""
    @Published var outputText = ""
    @Published var receiptPreviewText = ""
    @Published var currentPhase: LauncherPhase = .idle
    @Published var uiState: LauncherUIState = .idle
    @Published var statusMessage = "Select source and destination to start ingest."
    @Published var receiptPath = ""
    @Published var stagingPath = ""
    @Published var failureReason = ""
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

    private let phaseOrder: [LauncherPhase] = [.scan, .plan, .copy, .verify, .commit, .finalize]

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

    var overallProgressFraction: Double {
        guard uiState != .idle else {
            return 0
        }

        let totalUnits = 6.0
        var units = 0.0
        units += phaseBinaryProgress(.scan)
        units += phaseBinaryProgress(.plan)
        units += phaseWorkProgress(.copy, current: copiedCount)
        units += phaseWorkProgress(.verify, current: verifiedCount)
        units += phaseWorkProgress(.commit, current: committedCount)
        units += phaseBinaryProgress(.finalize)

        return min(1, max(0, units / totalUnits))
    }

    var phaseRows: [LauncherPhaseRowSnapshot] {
        phaseOrder.map { phase in
            LauncherPhaseRowSnapshot(
                phase: phase,
                visualState: visualState(for: phase),
                detail: phaseDetail(for: phase)
            )
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
        duplicateNotCopiedCount = 0
        copiedCount = 0
        verifiedCount = 0
        committedCount = 0
        receiptErrors = []
        touchedPaths = []
        seenErrorEventIndexes = []
        monitoredReceiptPath = ""
        receiptReadOffset = 0
        latestCorePhase = .scan
        currentPhase = .scan
        uiState = .running
        statusMessage = "Ingest is running."
        stopReceiptPolling()

        let process = Process()
        process.executableURL = cliExecutable
        process.arguments = ["--source", sourcePath, "--dest", destinationPath]

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
            appendOutput("[system] Running: \(cliExecutable.path) --source \(sourcePath) --dest \(destinationPath)")
        } catch {
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
            statusMessage = "Verified."
        case .failure:
            if failureReason.isEmpty {
                statusMessage = "Ingest failed (exit code \(exitCode))."
            } else {
                statusMessage = "Ingest failed: \(failureReason)"
            }
        }

        activeProcess = nil
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

    private func stopReceiptPolling() {
        receiptPollTimer?.invalidate()
        receiptPollTimer = nil
    }

    private func pollReceiptIfNeeded() {
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

    private func phaseBinaryProgress(_ phase: LauncherPhase) -> Double {
        switch uiState {
        case .idle:
            return 0
        case .success:
            return 1
        case .running:
            if rank(of: latestCorePhase) > rank(of: phase) {
                return 1
            }
            if latestCorePhase == phase {
                return 0.5
            }
            return 0
        case .failure:
            if rank(of: latestCorePhase) > rank(of: phase) {
                return 1
            }
            if latestCorePhase == phase {
                return 1
            }
            return 0
        }
    }

    private func phaseWorkProgress(_ phase: LauncherPhase, current: Int) -> Double {
        if uiState == .success {
            return 1
        }

        if plannedStageAndCommitCount > 0 {
            if current > 0 || rank(of: latestCorePhase) >= rank(of: phase) {
                return min(1, Double(current) / Double(plannedStageAndCommitCount))
            }
            return 0
        }

        return phaseBinaryProgress(phase)
    }

    private func visualState(for phase: LauncherPhase) -> LauncherPhaseVisualState {
        switch uiState {
        case .idle:
            return .pending
        case .running:
            if rank(of: phase) < rank(of: latestCorePhase) {
                return .complete
            }
            if phase == latestCorePhase {
                return .active
            }
            return .pending
        case .success:
            return .complete
        case .failure:
            if rank(of: phase) < rank(of: latestCorePhase) {
                return .complete
            }
            if phase == latestCorePhase {
                return .failed
            }
            return .pending
        }
    }

    private func phaseDetail(for phase: LauncherPhase) -> String {
        switch phase {
        case .plan:
            guard plannedStageAndCommitCount > 0 || duplicateNotCopiedCount > 0 else {
                return ""
            }
            return "\(plannedStageAndCommitCount) stage+commit, \(duplicateNotCopiedCount) duplicate"
        case .copy:
            guard plannedStageAndCommitCount > 0 else {
                return ""
            }
            return "\(copiedCount)/\(plannedStageAndCommitCount)"
        case .verify:
            guard plannedStageAndCommitCount > 0 else {
                return ""
            }
            return "\(verifiedCount)/\(plannedStageAndCommitCount)"
        case .commit:
            guard plannedStageAndCommitCount > 0 else {
                return ""
            }
            return "\(committedCount)/\(plannedStageAndCommitCount)"
        case .scan, .finalize, .idle, .finished:
            return ""
        }
    }

    private func rank(of phase: LauncherPhase) -> Int {
        switch phase {
        case .idle:
            return 0
        case .scan:
            return 1
        case .plan:
            return 2
        case .copy:
            return 3
        case .verify:
            return 4
        case .commit:
            return 5
        case .finalize:
            return 6
        case .finished:
            return 7
        }
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
    let isValid: Bool
    let browseAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.headline)

            HStack {
                TextField("Select a folder", text: $path)
                    .textFieldStyle(.roundedBorder)
                Button("Browse", action: browseAction)
            }

            if path.isEmpty {
                Text("No folder selected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text(isValid ? "Path is valid" : "Path is not valid")
                    .font(.caption)
                    .foregroundStyle(isValid ? .green : .red)
            }
        }
    }
}

struct LauncherPhaseRowView: View {
    let row: LauncherPhaseRowSnapshot

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: row.visualState.symbolName)
                .foregroundStyle(row.visualState.color)
            Text(row.phase.displayName)
                .font(.subheadline)
            Spacer(minLength: 8)
            if !row.detail.isEmpty {
                Text(row.detail)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct LauncherContentView: View {
    @StateObject private var viewModel = LauncherViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("rollkeep Launcher")
                .font(.title2)

            LauncherPathRow(
                title: "Source",
                path: $viewModel.sourcePath,
                isValid: viewModel.sourcePathValid,
                browseAction: viewModel.pickSourcePath
            )

            LauncherPathRow(
                title: "Destination",
                path: $viewModel.destinationPath,
                isValid: viewModel.destinationPathValid,
                browseAction: viewModel.pickDestinationPath
            )

            HStack(spacing: 14) {
                Button("Start Ingest", action: viewModel.startIngest)
                    .disabled(!viewModel.canStart)

                Text("Phase: \(viewModel.currentPhase.displayName)")
                    .font(.subheadline)

                Text("State: \(viewModel.uiState.label)")
                    .font(.subheadline)
            }

            ProgressView(value: viewModel.overallProgressFraction)

            VStack(alignment: .leading, spacing: 4) {
                Text("Phases")
                    .font(.headline)
                ForEach(viewModel.phaseRows) { row in
                    LauncherPhaseRowView(row: row)
                }
            }

            Text(viewModel.statusMessage)
                .font(.subheadline)

            if viewModel.uiState == .success {
                HStack(spacing: 10) {
                    Text("Verified")
                        .font(.headline)
                        .foregroundStyle(.green)
                    Button("Open receipt", action: viewModel.openReceipt)
                        .disabled(!viewModel.canOpenReceipt)
                }
            }

            if viewModel.uiState == .failure {
                HStack(spacing: 10) {
                    Button("Open receipt", action: viewModel.openReceipt)
                        .disabled(!viewModel.canOpenReceipt)
                    Button("Open staging folder", action: viewModel.openStagingFolder)
                        .disabled(!viewModel.canOpenStagingFolder)
                }
            }

            if !viewModel.failureReason.isEmpty {
                Text("Failure reason: \(viewModel.failureReason)")
                    .font(.subheadline)
                    .foregroundStyle(.red)
            }

            if !viewModel.receiptPath.isEmpty {
                Text("Receipt path: \(viewModel.receiptPath)")
                    .font(.caption)
                    .textSelection(.enabled)
            }

            if !viewModel.stagingPath.isEmpty {
                Text("Staging path: \(viewModel.stagingPath)")
                    .font(.caption)
                    .textSelection(.enabled)
            }

            if !viewModel.receiptErrors.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Errors")
                        .font(.headline)

                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(viewModel.receiptErrors, id: \.eventIndex) { error in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("[\(error.phase?.displayName ?? "Unknown")] \(error.message)")
                                        .font(.subheadline)
                                    if !error.paths.isEmpty {
                                        Text(error.paths.joined(separator: "\n"))
                                            .font(.caption.monospaced())
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(8)
                    }
                    .frame(maxHeight: 160)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }

            if !viewModel.touchedPaths.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Touched paths")
                        .font(.headline)

                    ScrollView {
                        Text(viewModel.touchedPaths.joined(separator: "\n"))
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .padding(8)
                    }
                    .frame(maxHeight: 140)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Live receipt (NDJSON)")
                    .font(.headline)
                ScrollView {
                    Text(viewModel.receiptPreviewText.isEmpty ? "Receipt events appear here as they are written." : viewModel.receiptPreviewText)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(8)
                }
                .frame(maxHeight: 180)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Command output")
                    .font(.headline)
                ScrollView {
                    Text(viewModel.outputText.isEmpty ? "Command output appears here." : viewModel.outputText)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(8)
                }
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
        .padding(16)
        .frame(minWidth: 960, minHeight: 760)
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
