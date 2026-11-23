import Foundation
import FyluroCore
import FyluroEngine
import SwiftUI

extension LauncherViewModel {
    var sourcePathValid: Bool {
        LauncherPathValidation.isValidSourcePath(sourcePath)
    }

    var destinationPathValid: Bool {
        LauncherPathValidation.isValidDestinationPath(destinationPath)
    }

    var sourceDestinationPairValid: Bool {
        LauncherPathValidation.isValidPathPair(sourcePath: sourcePath, destinationPath: destinationPath)
    }

    var canStart: Bool {
        !isRunning && sourcePathValid && destinationPathValid && sourceDestinationPairValid
    }

    var isImportReady: Bool {
        guard canStart, !isDestinationSpaceBlocking else {
            return false
        }

        if case .ready = sourceScanState {
            return true
        }

        return false
    }

    var isDestinationSpaceBlocking: Bool {
        destinationSpaceState.isBlocking
    }

    var isRunning: Bool {
        uiState == .running
    }

    var canOpenReceipt: Bool {
        preferredReceiptOpenPath != nil
    }

    var canOpenStagingFolder: Bool {
        !stagingPath.isEmpty && FileManager.default.fileExists(atPath: stagingPath)
    }

    var canOpenDestination: Bool {
        destinationPathValid
    }

    var canOpenSource: Bool {
        sourcePathValid
    }

    var newFinalMediaDirectories: [String] {
        filterNewFinalMediaDirectories(createdDirectories, destinationPath: destinationPath)
    }

    var canOpenNewFinalMediaDirectories: Bool {
        !newFinalMediaDirectories.isEmpty
    }

    var statusColor: Color {
        switch uiState {
        case .success:
            return LauncherTone.success.color
        case .failure:
            return LauncherTone.error.color
        case .running:
            return LauncherTone.info.color
        case .idle, .ready:
            return .primary
        }
    }

    /// The setup status line, only when it tells the user something the screen does not show.
    /// The "Choose …" messages repeat the empty route rows and the drop zone, and "Import ready"
    /// is the enabled Import button. What stays is a path problem or a rejected drop.
    var setupStatusNoticeText: String? {
        guard uiState == .idle else {
            return nil
        }
        let message = statusMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty, !message.hasPrefix("Choose ") else {
            return nil
        }
        return message
    }

    var setupScopeSummaryText: String {
        switch sourceScanState {
        case .idle:
            return "Select a source to preview inventory."
        case .scanning(let summary):
            if let summary, summary.itemCount > 0 {
                return "Scanning source media... \(summary.itemCount) items found so far."
            }
            return "Scanning source media..."
        case .ready(let summary):
            if summary.itemCount == 0 {
                return "No media found."
            }
            return ""
        case .failed(let message):
            return message
        }
    }

    var isSourceScanning: Bool {
        if case .scanning(_) = sourceScanState {
            return true
        }
        return false
    }

    var isSourceScanFailed: Bool {
        if case .failed = sourceScanState {
            return true
        }
        return false
    }

    var setupInventoryPlaceholderText: String {
        switch sourceScanState {
        case .idle, .ready:
            return "Scan details appear here once \(AppBrand.name) can inspect the selected source."
        case .scanning, .failed:
            return setupScopeSummaryText
        }
    }

    var setupEmptySourceMessage: String? {
        guard case .ready(let summary) = sourceScanState, summary.itemCount == 0 else {
            return nil
        }
        return setupScopeSummaryText
    }

    var setupInventory: LauncherSourceScopeSummary? {
        switch sourceScanState {
        case .scanning(let summary):
            return summary
        case .ready(let summary):
            return summary
        case .idle, .failed:
            return nil
        }
    }

    var setupInventoryCameraEntries: [LauncherSourceCameraSummary] {
        setupInventory?.cameraEntries ?? []
    }

    var setupInventorySizeText: String {
        formattedBytes(setupInventory?.totalBytes ?? 0)
    }

    var setupInventorySidecarNoteText: String? {
        setupInventory?.sidecarNoteText
    }

    var filmModeSummaryText: String? {
        guard case let .enabled(configuration) = filmModeState else {
            return nil
        }
        let months = Calendar.current.shortMonthSymbols
        let monthText = months.indices.contains(configuration.month - 1) ? months[configuration.month - 1] : ""
        let date = [monthText, String(configuration.year)].filter { !$0.isEmpty }.joined(separator: " ")
        return ["shot on \(configuration.camera)", configuration.filmStock, date]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    var destinationFreeSpaceRowText: String? {
        guard let outcome = destinationSpaceCheck else {
            return nil
        }
        switch outcome {
        case .sufficient(let availableBytes):
            return "\(formattedBytes(availableBytes)) free"
        case .insufficient(let details):
            return "\(formattedBytes(details.availableBytes)) free"
        case .unableToDetermine:
            return nil
        }
    }

    var destinationSpaceWarningText: String? {
        guard case .insufficient(let details) = destinationSpaceCheck,
              let bytesToCopy = setupInventory?.totalBytes else {
            return nil
        }
        return DestinationSpaceChecker.message(for: details, bytesToCopy: bytesToCopy)
    }

    var setupInventoryCaptureDateRangeText: String? {
        guard let range = setupInventory?.captureDateRange else {
            return nil
        }
        return formattedCaptureDateRange(start: range.start, end: range.end)
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

    var windowSubtitle: String {
        switch uiState {
        case .idle, .ready:
            return ""
        case .running:
            return importingTitle
        case .success:
            return completionTitle
        case .failure:
            return failureTitle
        }
    }

    var importingTitle: String {
        guard let total = importTotalCount, total > 0 else {
            return "Importing items…"
        }
        return total == 1 ? "Importing 1 item…" : "Importing \(total) items…"
    }

    var importingProgressText: String {
        if latestCorePhase == .verify {
            let verifyTotal = plannedStageAndCommitCount > 0 ? plannedStageAndCommitCount : importTotalCount
            if let total = verifyTotal, total > 0 {
                return "\(min(verifiedCount, total)) of \(total) items verified"
            }

            if verifiedCount > 0 {
                return "\(verifiedCount) items verified"
            }

            return "Verifying copied items"
        }

        if let total = importTotalCount, total > 0 {
            return "\(min(copiedCount, total)) of \(total) items copied"
        }

        if copiedCount > 0 {
            return "\(copiedCount) items copied"
        }

        return "Preparing items to copy"
    }

    var isImportScanPhase: Bool {
        latestCorePhase == .scan
    }

    var importingScanProgressText: String {
        let filesChecked = max(scannedFilesCheckedCount, scannedCandidateCount)
        let candidates = max(scannedCandidateCount, scannedPhotoCount + scannedVideoCount)
        let checkedBytes = max(scannedCheckedBytes, scannedTotalBytes)
        return "\(filesChecked) files checked • \(candidates) import candidates • \(formattedBytes(checkedBytes)) scanned"
    }

    var importingScanHeartbeatText: String {
        LauncherImportPresentation.scanHeartbeatText(
            now: Date(),
            lastProgressEventAt: lastProgressEventAt
        )
    }

    var importingPhaseDescription: String {
        LauncherImportPresentation.phaseDescription(for: latestCorePhase)
    }

    var copyByteFraction: Double? {
        guard bytesToCopy > 0 else {
            return nil
        }
        let copied = totalCopiedBytes > 0 ? totalCopiedBytes : copiedBytesByPath.values.reduce(Int64(0), +)
        return Double(copied) / Double(bytesToCopy)
    }

    var verifyByteFraction: Double? {
        guard bytesToCopy > 0 else {
            return nil
        }
        let verified = totalVerifiedBytes > 0 ? totalVerifiedBytes : verifiedBytesByPath.values.reduce(Int64(0), +)
        return Double(verified) / Double(bytesToCopy)
    }

    var scanProgressFraction: Double? {
        guard let previewTotal = lastPreviewSummary?.itemCount, previewTotal > 0 else {
            return nil
        }
        return Double(scannedCandidateCount) / Double(previewTotal)
    }

    var importingProgressFraction: Double {
        LauncherImportPresentation.progressFraction(
            phase: latestCorePhase,
            totalCount: importTotalCount,
            copiedCount: copiedCount,
            verifiedCount: verifiedCount,
            committedCount: committedCount,
            isSuccess: uiState == .success,
            copyByteFraction: copyByteFraction,
            verifyByteFraction: verifyByteFraction,
            scanFraction: scanProgressFraction
        )
    }

    var importingETA: String {
        LauncherImportPresentation.estimatedRemainingText(
            now: Date(),
            runStartedAt: runStartedAt,
            phase: latestCorePhase,
            copiedCount: copiedCount,
            progressFraction: importingProgressFraction
        )
    }

    var importingLiveBytesPerSecond: Double? {
        guard latestCorePhase == .copy || latestCorePhase == .verify else {
            return nil
        }
        return throughputTracker.liveBytesPerSecond(at: Date())
    }

    var importingDataRateText: String? {
        guard let rate = importingLiveBytesPerSecond else {
            return nil
        }
        return LauncherThroughputTracker.formattedRate(rate)
    }

    var importingETAWithRateText: String {
        guard let rateText = importingDataRateText else {
            return importingETA
        }
        return "\(importingETA) • \(rateText)"
    }

    var hasThroughputTelemetry: Bool {
        throughputTracker.hasTelemetryData
    }

    var shouldShowImportingThroughputToggle: Bool {
        switch latestCorePhase {
        case .copy, .verify, .commit, .finalize, .finished:
            return true
        case .idle, .scan, .plan:
            return false
        }
    }

    var formattedTotalCopiedBytes: String {
        guard throughputTracker.totalCopiedBytes > 0 else {
            return "0 B"
        }
        return formattedBytes(throughputTracker.totalCopiedBytes)
    }

    var formattedTotalVerifiedBytes: String {
        guard throughputTracker.totalVerifiedBytes > 0 else {
            return "0 B"
        }
        return formattedBytes(throughputTracker.totalVerifiedBytes)
    }

    var importingCurrentFileText: String? {
        let path = currentFilePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else {
            return nil
        }
        return path
    }

    var importingScanActivityText: String? {
        guard isImportScanPhase, let path = importingCurrentFileText else {
            return nil
        }
        return "Now scanning: \(path)"
    }

    var importSourceDisplayName: String {
        Self.displayName(forImportPath: sourcePath, fallback: "Source")
    }

    var importDestinationDisplayName: String {
        Self.displayName(forImportPath: destinationPath, fallback: "Destination")
    }

    var importSourceDisplayPath: String {
        Self.normalizedImportPath(sourcePath)
    }

    var importDestinationDisplayPath: String {
        Self.normalizedImportPath(destinationPath)
    }

    var committedOutcomeCount: Int {
        if finalizedCommittedCount > 0 || finalizedDuplicateNotCopiedCount > 0 {
            return finalizedCommittedCount
        }
        return committedCount
    }

    var duplicateNotCopiedOutcomeCount: Int {
        if finalizedCommittedCount > 0 || finalizedDuplicateNotCopiedCount > 0 {
            return finalizedDuplicateNotCopiedCount
        }
        return duplicateNotCopiedCount
    }

    var isIdempotentRerun: Bool {
        idempotentRerunDetected || (committedOutcomeCount == 0 && duplicateNotCopiedOutcomeCount > 0)
    }

    var completionTitle: String {
        "Import Complete"
    }

    var completionOutcomeText: String {
        if isIdempotentRerun {
            let duplicates = duplicateNotCopiedOutcomeCount
            if duplicates == 1 {
                return "No new files added. 1 file already exists in your library."
            }
            return "No new files added. All \(duplicates) files already exist in your library."
        }

        let imported = committedOutcomeCount
        let duplicates = duplicateNotCopiedOutcomeCount
        if duplicates > 0 {
            let importedText = imported == 1
                ? "1 file is verified in your library."
                : "\(imported) files are verified in your library."
            let duplicateText = duplicates == 1
                ? "1 duplicate skipped safely."
                : "\(duplicates) duplicates skipped safely."
            return "\(importedText) \(duplicateText)"
        }

        if imported == 1 {
            return "1 file is verified in your library."
        }
        if imported > 1 {
            return "All \(imported) files are verified in your library."
        }
        return "No new files added to your library."
    }

    var completionReceiptText: String {
        receiptPath.isEmpty ? "Receipt path unavailable" : "Receipt saved"
    }

    var hasRecordedErrors: Bool {
        !receiptErrors.isEmpty
    }

    var completionWarningEntries: [LauncherCompletionWarningEntry] {
        var seen = Set<String>()
        var ordered: [LauncherCompletionWarningEntry] = []
        for item in receiptErrors {
            for path in item.paths where seen.insert(path).inserted {
                ordered.append(LauncherCompletionWarningEntry(path: path, message: item.message))
            }
        }
        return ordered
    }

    var completionWarningTitle: String {
        let count = completionWarningEntries.count
        return count == 1
            ? "1 file could not be copied"
            : "\(count) files could not be copied"
    }

    var filmModeRawSkipNoticeText: String? {
        guard finalizedFilmModeExifSkippedCount > 0 else {
            return nil
        }
        let description = finalizedFilmModeExifSkippedCount == 1
            ? "1 RAW file kept its original camera metadata"
            : "\(finalizedFilmModeExifSkippedCount) RAW files kept their original camera metadata"
        return "Film Mode: \(description) — RAW files are not supported, but folder placement is still correct."
    }

    var completionDurationText: String? {
        guard let finalizedTotalDurationMs else {
            return nil
        }
        return LauncherImportPresentation.completionDurationText(milliseconds: finalizedTotalDurationMs)
    }

    var completionStats: [LauncherCompletionStat] {
        var stats = [
            LauncherCompletionStat(title: "Added to library", value: "\(committedOutcomeCount)"),
            LauncherCompletionStat(title: "Already in library", value: "\(duplicateNotCopiedOutcomeCount)"),
        ]
        if scannedTotalBytes > 0 {
            stats.append(LauncherCompletionStat(title: "Size", value: formattedBytes(scannedTotalBytes)))
        }
        if finalizedPhotoCount > 0 {
            stats.append(LauncherCompletionStat(title: "Photos", value: "\(finalizedPhotoCount)"))
        }
        if finalizedVideoCount > 0 {
            stats.append(LauncherCompletionStat(title: "Videos", value: "\(finalizedVideoCount)"))
        }
        if finalizedAudioCount > 0 {
            stats.append(LauncherCompletionStat(title: "Audio", value: "\(finalizedAudioCount)"))
        }
        // The run's own scan replaces the setup scan state and carries no camera data.
        // The preview summary from setup still has it.
        if let cameraCount = (lastPreviewSummary ?? setupInventory)?.detectedCameraCount, cameraCount > 0 {
            stats.append(LauncherCompletionStat(title: "Cameras", value: "\(cameraCount)"))
        }
        if finalizedConflictsRenamedCount > 0 {
            stats.append(LauncherCompletionStat(title: "Renamed", value: "\(finalizedConflictsRenamedCount)"))
        }
        if let finalizedTotalDurationMs {
            stats.append(
                LauncherCompletionStat(
                    title: "Elapsed",
                    value: LauncherImportPresentation.elapsedValueText(milliseconds: finalizedTotalDurationMs)
                )
            )
        }
        return stats
    }

    var completionSidecarNoteText: String? {
        LauncherSourceScopeSummary.sidecarNoteText(for: finalizedSidecarCount)
    }

    var completionFilmModeText: String? {
        guard let summary = filmModeSummaryText else {
            return nil
        }
        return "Film Mode — recorded as \(summary)"
    }

    var resultRouteStatus: LauncherRouteStatus {
        switch uiState {
        case .idle, .ready, .running:
            return .running
        case .success:
            return hasRecordedErrors ? .completeWithWarnings : .complete
        case .failure:
            return wasStoppedByUser ? .stopped : .failed
        }
    }

    var failureTitle: String {
        wasStoppedByUser ? "Import Stopped" : "Import Needs Attention"
    }

    var failureMessage: String {
        if !failureReason.isEmpty {
            return failureReason
        }
        return "The import did not finish."
    }

    private func filterNewFinalMediaDirectories(_ paths: [String], destinationPath: String) -> [String] {
        let trimmedDestination = destinationPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !paths.isEmpty, !trimmedDestination.isEmpty else {
            return []
        }

        let fileManager = FileManager.default
        let normalizedDestination = URL(fileURLWithPath: trimmedDestination, isDirectory: true).standardizedFileURL.path
        let destinationPrefix = normalizedDestination.hasSuffix("/") ? normalizedDestination : normalizedDestination + "/"

        var seen = Set<String>()
        var eligible: [String] = []

        for path in paths {
            let normalizedPath = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path

            guard normalizedPath == normalizedDestination || normalizedPath.hasPrefix(destinationPrefix) else {
                continue
            }
            guard !normalizedPath.contains("/_ingest_staging/"),
                  !normalizedPath.contains("/_ingest_receipts/") else {
                continue
            }
            let lowercasedPath = normalizedPath.lowercased()
            let isPhotosOrVideosDirectory = lowercasedPath.hasSuffix("/photos") || lowercasedPath.hasSuffix("/videos")
            let isSplitPhotoDirectory = lowercasedPath.hasSuffix("/photos/raw") || lowercasedPath.hasSuffix("/photos/non-raw")
            guard isPhotosOrVideosDirectory || isSplitPhotoDirectory else {
                continue
            }

            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: normalizedPath, isDirectory: &isDirectory), isDirectory.boolValue else {
                continue
            }

            if seen.insert(normalizedPath).inserted {
                eligible.append(normalizedPath)
            }
        }

        return eligible.sorted()
    }

    private func formattedBytes(_ value: Int64) -> String {
        Self.byteCountFormatter.string(fromByteCount: value)
    }

    private func formattedCaptureDateRange(start: Date, end: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDate(start, inSameDayAs: end) {
            return Self.captureDateRangeDayYearFormatter.string(from: start)
        }

        let sameYear = calendar.component(.year, from: start) == calendar.component(.year, from: end)
        let startText = sameYear
            ? Self.captureDateRangeDayFormatter.string(from: start)
            : Self.captureDateRangeDayYearFormatter.string(from: start)
        let endText = Self.captureDateRangeDayYearFormatter.string(from: end)
        return "\(startText) – \(endText)"
    }

    private static func normalizedImportPath(_ rawPath: String) -> String {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return ""
        }

        return URL(fileURLWithPath: trimmed, isDirectory: true).standardizedFileURL.path
    }

    private static func displayName(forImportPath rawPath: String, fallback: String) -> String {
        let normalizedPath = normalizedImportPath(rawPath)
        guard !normalizedPath.isEmpty else {
            return fallback
        }

        if normalizedPath == "/" {
            return "/"
        }

        let component = URL(fileURLWithPath: normalizedPath, isDirectory: true).lastPathComponent
        if !component.isEmpty {
            return component
        }

        return normalizedPath
    }
}
