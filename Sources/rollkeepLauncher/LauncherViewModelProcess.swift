import Foundation

extension LauncherViewModel {
    func startIngest() {
        guard canStart else {
            handlePathInputChanged(sourceChanged: false)
            if statusMessage == "Import ready" {
                statusMessage = "Choose a readable source and writable destination first."
            }
            return
        }

        guard let cliExecutable = cliExecutableResolver() else {
            uiState = .failure
            currentPhase = .finished
            statusMessage = "RollKeep CLI executable was not found."
            appendOutput("[system] Could not locate the sibling `rollkeep` executable next to the launcher binary.")
            return
        }

        sourceScanTask?.cancel()
        resetRunState()
        seedRunCountersFromPreviewSummary()

        latestCorePhase = .scan
        currentPhase = .scan
        uiState = .running
        statusMessage = "Preparing import..."
        stopReceiptPolling()
        runStartedAt = Date()
        lastProgressEventAt = runStartedAt
        ensureReceiptPollingTimer()
        appendOutput("[system] Using CLI executable: \(cliExecutable.path)")
        let pathSchemeSnapshot = pathSchemeSettingsStore.appliedConfiguration
        let arguments = Self.ingestArguments(
            sourcePath: sourcePath,
            destinationPath: destinationPath,
            pathSchemeConfiguration: pathSchemeSnapshot
        )

        let process = Process()
        process.executableURL = cliExecutable
        process.arguments = arguments
        process.environment = ingestProcessEnvironmentProvider()
        executedCommand = commandLine(executablePath: cliExecutable.path, arguments: arguments)

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

    func resetRunState() {
        parser = CLIOutputParser()
        receiptParser = ReceiptEventParser()
        parsedResult = nil
        stdoutCarry = ""
        stderrCarry = ""
        receiptCarry = ""
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
        finalizedTotalDurationMs = nil
        idempotentRerunDetected = false
        scannedPhotoCount = 0
        scannedVideoCount = 0
        scannedTotalBytes = 0
        scannedFilesCheckedCount = 0
        scannedCheckedBytes = 0
        receiptErrors = []
        touchedPaths = []
        createdDirectories = []
        seenErrorEventIndexes = []
        monitoredReceiptPath = ""
        receiptReadOffset = 0
        runStartedAt = nil
        lastProgressEventAt = nil
        progressCounters = LauncherProgressCounters()
        stopRequestedByUser = false
        wasStoppedByUser = false
    }

    func seedRunCountersFromPreviewSummary() {
        guard let summary = lastPreviewSummary else {
            return
        }

        scannedCandidateCount = max(scannedCandidateCount, summary.itemCount)
        scannedPhotoCount = max(scannedPhotoCount, summary.photoCount)
        scannedVideoCount = max(scannedVideoCount, summary.videoCount)
        scannedTotalBytes = max(scannedTotalBytes, summary.totalBytes)
        scannedFilesCheckedCount = max(scannedFilesCheckedCount, summary.itemCount)
        scannedCheckedBytes = max(scannedCheckedBytes, summary.totalBytes)
    }

    func handleTermination(process: Process, stdoutPipe: Pipe, stderrPipe: Pipe) {
        let finishedAt = Date()
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

}
