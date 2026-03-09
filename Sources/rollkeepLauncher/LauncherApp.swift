import AppKit
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

@MainActor
final class LauncherViewModel: ObservableObject {
    @Published var sourcePath = ""
    @Published var destinationPath = ""
    @Published var outputText = ""
    @Published var currentPhase: LauncherPhase = .idle
    @Published var uiState: LauncherUIState = .idle
    @Published var statusMessage = "Select source and destination to start ingest."
    @Published var receiptPath = ""
    @Published var failureReason = ""

    private var activeProcess: Process?
    private var parser = CLIOutputParser()
    private var stdoutCarry = ""
    private var stderrCarry = ""
    private var parsedResult: LauncherRunResult?

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

    var canRevealReceipt: Bool {
        !receiptPath.isEmpty && FileManager.default.fileExists(atPath: receiptPath)
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
        parsedResult = nil
        stdoutCarry = ""
        stderrCarry = ""
        receiptPath = ""
        failureReason = ""
        outputText = ""
        currentPhase = .scan
        uiState = .running
        statusMessage = "Ingest is running."

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

    func revealReceiptInFinder() {
        guard canRevealReceipt else {
            statusMessage = "Receipt file is not available to reveal."
            return
        }

        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: receiptPath)])
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

        let exitCode = Int(process.terminationStatus)
        appendOutput("[system] Process finished with exit code \(exitCode).")

        let result = parsedResult ?? (exitCode == 0 ? .success : .failure)
        uiState = result == .success ? .success : .failure
        currentPhase = .finished

        switch result {
        case .success:
            statusMessage = "Ingest completed successfully."
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
        }
        if let path = update.receiptPath, !path.isEmpty {
            receiptPath = path
        }
        if let reason = update.failureReason, !reason.isEmpty {
            failureReason = reason
        }
        if let result = update.result {
            parsedResult = result
        }
    }

    private func appendOutput(_ line: String) {
        if outputText.isEmpty {
            outputText = line
        } else {
            outputText.append("\n")
            outputText.append(line)
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

            Text(viewModel.statusMessage)
                .font(.subheadline)

            if !viewModel.receiptPath.isEmpty {
                HStack {
                    Text("Receipt: \(viewModel.receiptPath)")
                        .font(.subheadline)
                        .lineLimit(2)
                    Spacer(minLength: 8)
                    Button("Reveal Receipt in Finder", action: viewModel.revealReceiptInFinder)
                        .disabled(!viewModel.canRevealReceipt)
                }
            }

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
        .padding(16)
        .frame(minWidth: 920, minHeight: 640)
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
