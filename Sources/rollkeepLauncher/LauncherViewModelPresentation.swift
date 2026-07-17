import Foundation
import RollKeepEngine
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
        guard case .insufficient = destinationSpaceCheck else {
            return false
        }
        return !destinationSpaceOverrideAccepted
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

    /// True fraction of planned bytes copied so far, when the plan's byte total
    /// is known. Drives a byte-accurate copy progress band.
    var copyByteFraction: Double? {
        guard bytesToCopy > 0 else {
            return nil
        }
        let copied = copiedBytesByPath.values.reduce(Int64(0), +)
        return Double(copied) / Double(bytesToCopy)
    }

    /// Fraction of expected candidates discovered so far, using the stable
    /// pre-ingest preview count as the denominator. Drives a determinate scan
    /// band; nil when no preview count is available (falls back to a fixed value).
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

    var completionItemsText: String {
        if isIdempotentRerun {
            let duplicates = duplicateNotCopiedOutcomeCount
            if duplicates == 1 {
                return "No new items imported; 1 item already exists in the library"
            }
            return "No new items imported; \(duplicates) items already exist in the library"
        }

        let imported = committedOutcomeCount
        return imported == 1 ? "1 item imported" : "\(imported) items imported"
    }

    var completionOutcomeText: String {
        if isIdempotentRerun {
            return "Idempotent rerun confirmed. Existing files were preserved without overwrite."
        }

        let duplicates = duplicateNotCopiedOutcomeCount
        if duplicates > 0 {
            return duplicates == 1
                ? "1 duplicate was detected and skipped safely."
                : "\(duplicates) duplicates were detected and skipped safely."
        }

        return "New files were committed to your library."
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

    var completionDurationText: String? {
        guard let finalizedTotalDurationMs else {
            return nil
        }
        return LauncherImportPresentation.completionDurationText(milliseconds: finalizedTotalDurationMs)
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
