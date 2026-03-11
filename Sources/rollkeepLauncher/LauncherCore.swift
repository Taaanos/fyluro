import Foundation
import RollKeepCore

struct LauncherMountedVolume: Equatable {
    let path: String
    let hasDCIM: Bool
    let isRemovable: Bool?

    var heuristicScore: Int {
        var score = 0
        if hasDCIM {
            score += 3
        }
        if isRemovable == true {
            score += 1
        }
        return score
    }
}

protocol LauncherVolumeInspecting {
    func mountedVolumes() -> [LauncherMountedVolume]
    func likelyCardVolumes() -> [LauncherMountedVolume]
}

struct LauncherVolumeInspector: LauncherVolumeInspecting {
    let volumesRoot: URL
    let fileManager: FileManager
    private let removableHintProvider: (URL) -> Bool?

    init(
        volumesRoot: URL = URL(fileURLWithPath: "/Volumes", isDirectory: true),
        fileManager: FileManager = .default,
        removableHintProvider: @escaping (URL) -> Bool? = LauncherVolumeInspector.defaultRemovableHint(for:)
    ) {
        self.volumesRoot = volumesRoot
        self.fileManager = fileManager
        self.removableHintProvider = removableHintProvider
    }

    func mountedVolumes() -> [LauncherMountedVolume] {
        let resourceKeys: Set<URLResourceKey> = [.isDirectoryKey, .isHiddenKey]
        let volumeURLs: [URL]
        do {
            volumeURLs = try fileManager.contentsOfDirectory(
                at: volumesRoot,
                includingPropertiesForKeys: Array(resourceKeys),
                options: [.skipsHiddenFiles]
            )
        } catch {
            return []
        }

        var volumes: [LauncherMountedVolume] = []
        volumes.reserveCapacity(volumeURLs.count)

        for volumeURL in volumeURLs {
            guard let values = try? volumeURL.resourceValues(forKeys: resourceKeys),
                  values.isDirectory == true,
                  values.isHidden != true else {
                continue
            }

            let standardizedPath = volumeURL.standardizedFileURL.path
            var dcimIsDirectory: ObjCBool = false
            let hasDCIM = fileManager.fileExists(
                atPath: volumeURL.appendingPathComponent("DCIM", isDirectory: true).path,
                isDirectory: &dcimIsDirectory
            ) && dcimIsDirectory.boolValue

            volumes.append(LauncherMountedVolume(
                path: standardizedPath,
                hasDCIM: hasDCIM,
                isRemovable: removableHintProvider(volumeURL)
            ))
        }

        return volumes.sorted(by: LauncherVolumeInspector.sortVolumes(_:_:))
    }

    func likelyCardVolumes() -> [LauncherMountedVolume] {
        mountedVolumes()
            .filter { $0.hasDCIM || $0.isRemovable == true }
            .sorted(by: LauncherVolumeInspector.sortLikelyVolumes(_:_:))
    }

    private static func sortVolumes(_ lhs: LauncherMountedVolume, _ rhs: LauncherMountedVolume) -> Bool {
        lhs.path < rhs.path
    }

    private static func sortLikelyVolumes(_ lhs: LauncherMountedVolume, _ rhs: LauncherMountedVolume) -> Bool {
        if lhs.heuristicScore != rhs.heuristicScore {
            return lhs.heuristicScore > rhs.heuristicScore
        }
        return lhs.path < rhs.path
    }

    private static func defaultRemovableHint(for volumeURL: URL) -> Bool? {
        let keys: Set<URLResourceKey> = [.volumeIsRemovableKey]
        guard let values = try? volumeURL.resourceValues(forKeys: keys) else {
            return nil
        }
        return values.volumeIsRemovable
    }
}

protocol LauncherSourceDefaulting {
    func suggestedSourcePath() -> String?
}

struct LauncherSourceAutoPicker: LauncherSourceDefaulting {
    let inspector: LauncherVolumeInspecting

    init(inspector: LauncherVolumeInspecting = LauncherVolumeInspector()) {
        self.inspector = inspector
    }

    func suggestedSourcePath() -> String? {
        inspector.likelyCardVolumes().first?.path
    }
}

protocol LauncherDestinationDefaulting {
    func suggestedDestinationPath() -> String?
}

protocol LauncherDestinationRemembering {
    func loadLastDestinationPath() -> String?
    func saveLastDestinationPath(_ path: String)
}

struct LauncherDestinationMemory: LauncherDestinationRemembering {
    let userDefaults: UserDefaults
    let key: String

    init(
        userDefaults: UserDefaults = .standard,
        key: String = "rollkeep.launcher.lastDestinationPath"
    ) {
        self.userDefaults = userDefaults
        self.key = key
    }

    func loadLastDestinationPath() -> String? {
        guard let path = userDefaults.string(forKey: key)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty else {
            return nil
        }

        return path
    }

    func saveLastDestinationPath(_ path: String) {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            userDefaults.removeObject(forKey: key)
            return
        }

        userDefaults.set(trimmed, forKey: key)
    }
}

struct LauncherDestinationAutoPicker: LauncherDestinationDefaulting {
    let memory: LauncherDestinationRemembering
    let fallback: LauncherDestinationDefaulting?

    init(
        memory: LauncherDestinationRemembering = LauncherDestinationMemory(),
        fallback: LauncherDestinationDefaulting? = LauncherReceiptBasedDestinationDefault()
    ) {
        self.memory = memory
        self.fallback = fallback
    }

    func suggestedDestinationPath() -> String? {
        if let remembered = memory.loadLastDestinationPath() {
            return remembered
        }

        return fallback?.suggestedDestinationPath()
    }
}

struct LauncherReceiptBasedDestinationDefault: LauncherDestinationDefaulting {
    let inspector: LauncherVolumeInspecting
    let fileManager: FileManager

    init(
        inspector: LauncherVolumeInspecting = LauncherVolumeInspector(),
        fileManager: FileManager = .default
    ) {
        self.inspector = inspector
        self.fileManager = fileManager
    }

    func suggestedDestinationPath() -> String? {
        var bestMatch: (path: String, modifiedAt: Date)?
        let keys: Set<URLResourceKey> = [.contentModificationDateKey]

        for volume in inspector.mountedVolumes() {
            let receiptsURL = URL(fileURLWithPath: volume.path, isDirectory: true)
                .appendingPathComponent("_ingest_receipts", isDirectory: true)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: receiptsURL.path, isDirectory: &isDirectory),
                  isDirectory.boolValue,
                  let values = try? receiptsURL.resourceValues(forKeys: keys),
                  let modifiedAt = values.contentModificationDate else {
                continue
            }

            if let currentMatch = bestMatch {
                if modifiedAt > currentMatch.modifiedAt {
                    bestMatch = (volume.path, modifiedAt)
                }
            } else {
                bestMatch = (volume.path, modifiedAt)
            }
        }

        return bestMatch?.path
    }
}

enum LauncherPhase: String, Equatable {
    case idle
    case scan
    case plan
    case copy
    case verify
    case commit
    case finalize
    case finished

    var displayName: String {
        switch self {
        case .idle:
            return "Idle"
        case .scan:
            return "Scan"
        case .plan:
            return "Plan"
        case .copy:
            return "Copy"
        case .verify:
            return "Verify"
        case .commit:
            return "Commit"
        case .finalize:
            return "Finalize"
        case .finished:
            return "Finished"
        }
    }

    static func fromReceiptPhase(_ value: String) -> LauncherPhase? {
        switch value {
        case "scan":
            return .scan
        case "plan":
            return .plan
        case "copy":
            return .copy
        case "verify":
            return .verify
        case "commit":
            return .commit
        case "finalize":
            return .finalize
        default:
            return nil
        }
    }
}

enum LauncherRunResult: Equatable {
    case success
    case failure
}

struct ParsedOutputUpdate: Equatable {
    var phase: LauncherPhase?
    var receiptPath: String?
    var pdfSummaryPath: String?
    var stagingPath: String?
    var result: LauncherRunResult?
    var failureReason: String?
    var idempotentRerun: Bool?
}

struct CLIOutputParser {
    mutating func parse(line: String) -> ParsedOutputUpdate {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return ParsedOutputUpdate()
        }

        var update = ParsedOutputUpdate()

        if let payload = parseJSONObject(from: trimmed) {
            if let receiptPath = payload["receipt_path"] as? String {
                update.receiptPath = receiptPath
            }

            if let stagingPath = payload["staging_session_path"] as? String {
                update.stagingPath = stagingPath
            }

            if let message = payload["message"] as? String,
               let mappedPhase = phase(forLogMessage: message) {
                update.phase = mappedPhase
            }
        }

        if trimmed == "Rollkeep Final Summary" {
            update.phase = .finalize
        }

        if trimmed.hasPrefix("Status: ") {
            let label = String(trimmed.dropFirst("Status: ".count)).uppercased()
            if label.contains("FAILED") {
                update.phase = .finished
                update.result = .failure
            } else if label.contains("VERIFIED") || label.contains("COMPLETED") || label.contains("DRY RUN") {
                update.phase = .finished
                update.result = .success
            }
        }

        if trimmed.hasPrefix("Receipt: ") {
            let rawValue = String(trimmed.dropFirst("Receipt: ".count))
            if let markerRange = rawValue.range(of: " [", options: .backwards) {
                update.receiptPath = String(rawValue[..<markerRange.lowerBound])
            } else {
                update.receiptPath = rawValue
            }
        }

        if trimmed.hasPrefix("PDF summary: ") {
            update.pdfSummaryPath = String(trimmed.dropFirst("PDF summary: ".count))
        }

        if trimmed.hasPrefix("- phase: ") {
            let phaseName = String(trimmed.dropFirst("- phase: ".count))
            if let mappedPhase = LauncherPhase.fromReceiptPhase(phaseName) {
                update.phase = mappedPhase
            }
        }

        if trimmed.hasPrefix("- reason: ") {
            update.failureReason = String(trimmed.dropFirst("- reason: ".count))
        }

        if trimmed.hasPrefix("- staging: ") {
            update.stagingPath = String(trimmed.dropFirst("- staging: ".count))
        }

        if trimmed.hasPrefix("Idempotency: ") {
            let label = String(trimmed.dropFirst("Idempotency: ".count))
            let classification = label
                .split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
                .first
                .map(String.init)?
                .lowercased()
            if let classification {
                update.idempotentRerun = classification == "idempotent_rerun"
            }
        }

        return update
    }

    private func parseJSONObject(from value: String) -> [String: Any]? {
        guard let data = value.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let payload = object as? [String: Any] else {
            return nil
        }
        return payload
    }

    private func phase(forLogMessage message: String) -> LauncherPhase? {
        switch message {
        case "command_started":
            return .scan
        case "scan_summary":
            return .plan
        case "plan_summary":
            return .copy
        case "copy_stage_completed":
            return .verify
        case "commit_stage_completed":
            return .commit
        case "dry_run_complete", "staging_session_removed", "receipt_pdf_written", "receipt_pdf_write_failed":
            return .finalize
        default:
            break
        }

        if message.contains("scan") {
            return .scan
        }
        if message.contains("plan") {
            return .plan
        }
        if message.contains("copy") {
            return .copy
        }
        if message.contains("verify") {
            return .verify
        }
        if message.contains("commit") {
            return .commit
        }
        if message.contains("finalize") || message.contains("receipt") {
            return .finalize
        }

        return nil
    }
}

struct ReceiptErrorItem: Equatable {
    let eventIndex: Int
    let phase: LauncherPhase?
    let message: String
    let paths: [String]
}

struct ParsedReceiptUpdate: Equatable {
    struct PhaseTiming: Equatable {
        let phase: LauncherPhase
        let milliseconds: Int
    }

    var phase: LauncherPhase?
    var scannedCandidateCount: Int?
    var scanPhotoCount: Int? = nil
    var scanVideoCount: Int? = nil
    var scanPhotoBytes: Int64? = nil
    var scanVideoBytes: Int64? = nil
    var plannedStageAndCommit: Int?
    var duplicateNotCopied: Int?
    var copiedIncrement = 0
    var verifiedIncrement = 0
    var committedIncrement = 0
    var finalizedCommittedCount: Int?
    var finalizedDuplicateNotCopiedCount: Int?
    var finalizedIdempotentRerun: Bool?
    var finalizedPhaseTimings: [PhaseTiming]?
    var finalizedTotalDurationMs: Int?
    var pdfSummaryPath: String?
    var errorItem: ReceiptErrorItem?
    var touchedPaths: [String]?
    var createdDirectories: [String]?
}

struct ReceiptEventParser {
    mutating func parse(line: String) -> ParsedReceiptUpdate {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let payload = parseJSONObject(from: trimmed) else {
            return ParsedReceiptUpdate()
        }

        var update = ParsedReceiptUpdate()
        if let phaseRaw = payload["phase"] as? String {
            update.phase = LauncherPhase.fromReceiptPhase(phaseRaw)
        }

        guard let eventType = payload["event_type"] as? String else {
            return update
        }

        let eventIndex = intValue(from: payload["event_index"]) ?? 0
        let data = payload["data"] as? [String: Any] ?? [:]

        switch eventType {
        case "SCAN_SUMMARY":
            update.scannedCandidateCount = intValue(from: data["candidate_count"])
            if let photos = data["photos"] as? [String: Any] {
                update.scanPhotoCount = intValue(from: photos["count"])
                update.scanPhotoBytes = int64Value(from: photos["bytes"])
            }
            if let videos = data["videos"] as? [String: Any] {
                update.scanVideoCount = intValue(from: videos["count"])
                update.scanVideoBytes = int64Value(from: videos["bytes"])
            }
        case "PLAN_COMPUTED":
            if let files = data["files"] as? [[String: Any]] {
                update.plannedStageAndCommit = files.reduce(0) { partial, file in
                    partial + ((file["outcome"] as? String) == "stage_and_commit" ? 1 : 0)
                }
                update.duplicateNotCopied = files.reduce(0) { partial, file in
                    partial + ((file["outcome"] as? String) == "duplicate_not_copied" ? 1 : 0)
                }
            } else {
                update.plannedStageAndCommit = intValue(from: data["planned_file_count"])
                update.duplicateNotCopied = intValue(from: data["duplicate_not_copied_count"])
            }
        case "FILE_COPY_STARTED":
            guard boolValue(from: data["executed"]) != false else {
                return update
            }
            let status = (data["status"] as? String)?.lowercased()
            if status != "queued" && status != "planned" {
                update.copiedIncrement = 1
            }
        case "FILE_VERIFIED":
            guard boolValue(from: data["executed"]) != false else {
                return update
            }
            if data["outcome"] as? String == "verified" {
                update.verifiedIncrement = 1
            }
        case "FILE_COMMITTED":
            guard boolValue(from: data["executed"]) != false else {
                return update
            }
            if data["status"] as? String != "not_attempted_due_to_prior_failure" {
                update.committedIncrement = 1
            }
        case "ERROR":
            let message = (data["error"] as? String) ?? "Unknown error"
            update.errorItem = ReceiptErrorItem(
                eventIndex: eventIndex,
                phase: update.phase,
                message: message,
                paths: extractErrorPaths(from: data)
            )
        case "SUMMARY":
            if let outcomes = data["totals_by_outcome"] as? [String: Any] {
                update.finalizedCommittedCount = intValue(from: outcomes["committed"])
                update.finalizedDuplicateNotCopiedCount = intValue(from: outcomes["duplicate_not_copied"])

                if let committed = update.finalizedCommittedCount,
                   let duplicates = update.finalizedDuplicateNotCopiedCount {
                    let dryRun = boolValue(from: data["dry_run"]) ?? false
                    let status = (data["status"] as? String)?.lowercased() ?? ""
                    update.finalizedIdempotentRerun = !dryRun && status == "completed" && committed == 0 && duplicates > 0
                }
            }
            let phaseTimings = parsePhaseTimings(data["phase_timings_ms"])
            if !phaseTimings.isEmpty {
                update.finalizedPhaseTimings = phaseTimings
                update.finalizedTotalDurationMs = phaseTimings.reduce(0) { partial, timing in
                    partial + timing.milliseconds
                }
            }
            if let touched = data["touched_paths"] as? [String: Any] {
                update.touchedPaths = flattenTouchedPaths(touched)
                update.createdDirectories = extractStringArray(touched["created_directories"])
            }
            if let pdfSummaryPath = data["pdf_summary_path"] as? String,
               !pdfSummaryPath.isEmpty,
               pdfSummaryPath != "not_written" {
                update.pdfSummaryPath = pdfSummaryPath
            }
        default:
            break
        }

        return update
    }

    private func parseJSONObject(from value: String) -> [String: Any]? {
        guard let data = value.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let payload = object as? [String: Any] else {
            return nil
        }
        return payload
    }

    private func intValue(from value: Any?) -> Int? {
        if let integer = value as? Int {
            return integer
        }
        if let number = value as? NSNumber {
            return number.intValue
        }
        if let text = value as? String {
            return Int(text)
        }
        return nil
    }

    private func int64Value(from value: Any?) -> Int64? {
        if let integer = value as? Int64 {
            return integer
        }
        if let integer = value as? Int {
            return Int64(integer)
        }
        if let number = value as? NSNumber {
            return number.int64Value
        }
        if let text = value as? String {
            return Int64(text)
        }
        return nil
    }

    private func boolValue(from value: Any?) -> Bool? {
        if let bool = value as? Bool {
            return bool
        }
        if let number = value as? NSNumber {
            return number.boolValue
        }
        if let text = value as? String {
            switch text.lowercased() {
            case "true":
                return true
            case "false":
                return false
            default:
                return nil
            }
        }
        return nil
    }

    private func extractErrorPaths(from data: [String: Any]) -> [String] {
        var paths: [String] = []
        let directPathKeys = [
            "path",
            "source_path",
            "staging_path",
            "final_path",
            "planned_final_path",
            "attempted_final_path",
        ]

        for key in directPathKeys {
            if let path = data[key] as? String, !path.isEmpty {
                paths.append(path)
            }
        }

        if let moved = data["moved_before_failure"] as? [[String: Any]] {
            for entry in moved {
                if let stagingPath = entry["staging_path"] as? String, !stagingPath.isEmpty {
                    paths.append(stagingPath)
                }
                if let finalPath = entry["final_path"] as? String, !finalPath.isEmpty {
                    paths.append(finalPath)
                }
            }
        }

        if let remaining = data["remaining_after_failure"] as? [[String: Any]] {
            for entry in remaining {
                if let stagingPath = entry["staging_path"] as? String, !stagingPath.isEmpty {
                    paths.append(stagingPath)
                }
                if let finalPath = entry["planned_final_path"] as? String, !finalPath.isEmpty {
                    paths.append(finalPath)
                }
            }
        }

        return deduped(paths)
    }

    private func flattenTouchedPaths(_ touched: [String: Any]) -> [String] {
        var paths: [String] = []

        for value in touched.values {
            if let directPaths = value as? [String] {
                paths.append(contentsOf: directPaths.filter { !$0.isEmpty })
                continue
            }

            if let moveEntries = value as? [[String: Any]] {
                for entry in moveEntries {
                    if let from = entry["from"] as? String, !from.isEmpty {
                        paths.append(from)
                    }
                    if let to = entry["to"] as? String, !to.isEmpty {
                        paths.append(to)
                    }
                    if let stagingPath = entry["staging_path"] as? String, !stagingPath.isEmpty {
                        paths.append(stagingPath)
                    }
                    if let finalPath = entry["final_path"] as? String, !finalPath.isEmpty {
                        paths.append(finalPath)
                    }
                    if let plannedFinalPath = entry["planned_final_path"] as? String, !plannedFinalPath.isEmpty {
                        paths.append(plannedFinalPath)
                    }
                }
            }
        }

        return deduped(paths)
    }

    private func deduped(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for value in values where !value.isEmpty {
            if seen.insert(value).inserted {
                ordered.append(value)
            }
        }
        return ordered
    }

    private func extractStringArray(_ value: Any?) -> [String]? {
        guard let values = value as? [String] else {
            return nil
        }
        return deduped(values.filter { !$0.isEmpty })
    }

    private func parsePhaseTimings(_ value: Any?) -> [ParsedReceiptUpdate.PhaseTiming] {
        guard let entries = value as? [[String: Any]] else {
            return []
        }

        var timings: [ParsedReceiptUpdate.PhaseTiming] = []
        for entry in entries {
            guard let phaseRaw = entry["phase"] as? String,
                  let phase = LauncherPhase.fromReceiptPhase(phaseRaw),
                  let milliseconds = intValue(from: entry["milliseconds"]) else {
                continue
            }

            timings.append(.init(phase: phase, milliseconds: max(milliseconds, 0)))
        }

        return timings
    }
}

struct LauncherProgressCounters: Equatable {
    private(set) var scannedCandidateCount = 0
    private(set) var plannedStageAndCommitCount = 0
    private(set) var duplicateNotCopiedCount = 0
    private(set) var copiedCount = 0
    private(set) var verifiedCount = 0
    private(set) var committedCount = 0
    private(set) var preferredTotalCount: Int?
    private(set) var fallbackTotalCount: Int?

    var totalCount: Int? {
        preferredTotalCount ?? fallbackTotalCount
    }

    @discardableResult
    mutating func apply(_ update: ParsedReceiptUpdate) -> Bool {
        var progressChanged = false

        if let scanned = update.scannedCandidateCount {
            let normalized = max(scanned, 0)
            if normalized > scannedCandidateCount {
                scannedCandidateCount = normalized
                progressChanged = true
            }
            preferredTotalCount = maxOptional(preferredTotalCount, normalized)
        }

        if let planned = update.plannedStageAndCommit {
            let normalized = max(planned, 0)
            if normalized > plannedStageAndCommitCount {
                plannedStageAndCommitCount = normalized
                progressChanged = true
            }
        }

        if let duplicates = update.duplicateNotCopied {
            let normalized = max(duplicates, 0)
            if normalized > duplicateNotCopiedCount {
                duplicateNotCopiedCount = normalized
                progressChanged = true
            }
        }

        let hasPlanTotals = update.plannedStageAndCommit != nil || update.duplicateNotCopied != nil || fallbackTotalCount != nil
        if hasPlanTotals {
            let fallback = max(plannedStageAndCommitCount + duplicateNotCopiedCount, 0)
            fallbackTotalCount = maxOptional(fallbackTotalCount, fallback)
        }

        if update.copiedIncrement > 0 {
            copiedCount += update.copiedIncrement
            progressChanged = true
        }
        if update.verifiedIncrement > 0 {
            verifiedCount += update.verifiedIncrement
            progressChanged = true
        }
        if update.committedIncrement > 0 {
            committedCount += update.committedIncrement
            progressChanged = true
        }

        clampCounters()
        return progressChanged
    }

    private mutating func clampCounters() {
        guard let totalCount else {
            return
        }

        copiedCount = min(copiedCount, totalCount)
        verifiedCount = min(verifiedCount, totalCount)
        committedCount = min(committedCount, totalCount)
    }

    private func maxOptional(_ current: Int?, _ candidate: Int) -> Int {
        if let current {
            return max(current, candidate)
        }
        return candidate
    }
}

struct LauncherStatusTextBuilder {
    static func runningStatus(
        phase: LauncherPhase,
        totalCount: Int?,
        scannedCandidateCount: Int,
        copiedCount: Int,
        verifiedCount: Int,
        committedCount: Int,
        now: Date,
        runStartedAt: Date?,
        lastProgressEventAt: Date?,
        heartbeatAfter: TimeInterval = 2.0
    ) -> String {
        let base = baseStatus(
            phase: phase,
            totalCount: totalCount,
            scannedCandidateCount: scannedCandidateCount,
            copiedCount: copiedCount,
            verifiedCount: verifiedCount,
            committedCount: committedCount
        )

        guard shouldShowHeartbeat(
            now: now,
            runStartedAt: runStartedAt,
            lastProgressEventAt: lastProgressEventAt,
            heartbeatAfter: heartbeatAfter
        ) else {
            return base
        }

        return "\(base) Still working... \(elapsedString(now: now, runStartedAt: runStartedAt))"
    }

    static func baseStatus(
        phase: LauncherPhase,
        totalCount: Int?,
        scannedCandidateCount: Int,
        copiedCount: Int,
        verifiedCount: Int,
        committedCount: Int
    ) -> String {
        if let totalCount {
            switch phase {
            case .plan:
                return "Running plan for \(totalCount) files..."
            case .copy:
                return "Running copy \(copiedCount)/\(totalCount) files..."
            case .verify:
                return "Running verify \(verifiedCount)/\(totalCount) files..."
            case .commit:
                return "Running commit \(committedCount)/\(totalCount) files..."
            case .finalize, .finished:
                return "Finalizing ingest..."
            case .idle, .scan:
                return "Running scan..."
            }
        }

        switch phase {
        case .finished:
            return "Finishing ingest..."
        case .finalize:
            return "Finalizing ingest..."
        case .idle:
            return "Starting ingest..."
        case .scan where scannedCandidateCount > 0:
            return "Running scan... \(scannedCandidateCount) files found so far."
        case .plan where scannedCandidateCount > 0:
            return "Running plan for \(scannedCandidateCount) files..."
        default:
            return "Running \(phase.displayName.lowercased())..."
        }
    }

    static func shouldShowHeartbeat(
        now: Date,
        runStartedAt: Date?,
        lastProgressEventAt: Date?,
        heartbeatAfter: TimeInterval
    ) -> Bool {
        guard runStartedAt != nil,
              let lastProgressEventAt else {
            return false
        }

        return now.timeIntervalSince(lastProgressEventAt) > heartbeatAfter
    }

    static func elapsedString(now: Date, runStartedAt: Date?) -> String {
        guard let runStartedAt else {
            return "00:00"
        }

        let elapsed = max(0, Int(now.timeIntervalSince(runStartedAt)))
        let minutes = elapsed / 60
        let seconds = elapsed % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

struct LauncherSourceScopeSummary: Equatable {
    let itemCount: Int
    let photoCount: Int
    let videoCount: Int
    let totalBytes: Int64
    let cameraEntries: [LauncherSourceCameraSummary]

    init(
        itemCount: Int,
        photoCount: Int,
        videoCount: Int,
        totalBytes: Int64,
        cameraEntries: [LauncherSourceCameraSummary] = []
    ) {
        self.itemCount = itemCount
        self.photoCount = photoCount
        self.videoCount = videoCount
        self.totalBytes = totalBytes
        self.cameraEntries = cameraEntries
    }

    init(snapshot: ScanProgressSnapshot) {
        self.init(
            itemCount: snapshot.itemCount,
            photoCount: snapshot.photoCount,
            videoCount: snapshot.videoCount,
            totalBytes: snapshot.totalBytes,
            cameraEntries: Self.cameraEntries(from: snapshot.cameraAssessment)
        )
    }

    init(summary: ScanSummary) {
        self.init(
            itemCount: summary.candidates.count,
            photoCount: summary.photoCount,
            videoCount: summary.videoCount,
            totalBytes: summary.photoBytes + summary.videoBytes,
            cameraEntries: Self.cameraEntries(from: summary.cameraAssessment)
        )
    }

    init(preparation: IngestPreparation) {
        self.init(
            itemCount: preparation.scanSummary.candidates.count,
            photoCount: preparation.scanSummary.photoCount,
            videoCount: preparation.scanSummary.videoCount,
            totalBytes: preparation.scanSummary.photoBytes + preparation.scanSummary.videoBytes,
            cameraEntries: Self.cameraEntries(from: preparation.cameraAssessment)
        )
    }

    var mediaDescription: String {
        switch (photoCount > 0, videoCount > 0) {
        case (true, true):
            return "Photos and videos"
        case (true, false):
            return "Photos"
        case (false, true):
            return "Videos"
        default:
            return "No media found"
        }
    }

    var detectedCameraCount: Int {
        cameraEntries.filter { !$0.isUnknown }.count
    }

    private static func cameraEntries(from assessment: CameraCardAssessment) -> [LauncherSourceCameraSummary] {
        assessment.distribution.map { entry in
            LauncherSourceCameraSummary(label: entry.cameraLabel, fileCount: entry.fileCount)
        }
    }
}

struct LauncherSourceCameraSummary: Equatable, Identifiable {
    let label: String
    let fileCount: Int

    var id: String { label }

    var isUnknown: Bool {
        label == CameraLabeler.unknownLabel
    }

    var displayLabel: String {
        isUnknown ? "Unknown camera" : label
    }
}

protocol LauncherSourceScanning: Sendable {
    func scan(
        sourcePath: String,
        mode: SourceScanMode,
        progress: (@Sendable (ScanProgressSnapshot) -> Void)?
    ) throws -> IngestPreparation
}

struct LauncherSharedSourceScanner: LauncherSourceScanning {
    func scan(
        sourcePath: String,
        mode: SourceScanMode = .deep,
        progress: (@Sendable (ScanProgressSnapshot) -> Void)? = nil
    ) throws -> IngestPreparation {
        try IngestPreparationService().scan(
            sourceRoot: URL(fileURLWithPath: sourcePath, isDirectory: true),
            mode: mode,
            progress: progress
        )
    }
}

struct LauncherImportPresentation {
    static func phaseDescription(for phase: LauncherPhase) -> String {
        switch phase {
        case .idle:
            return "Preparing import"
        case .scan:
            return "Scanning source media"
        case .plan:
            return "Planning destination layout"
        case .copy:
            return "Creating verified copy"
        case .verify:
            return "Verifying copied files"
        case .commit:
            return "Saving files to library"
        case .finalize, .finished:
            return "Finalizing receipt"
        }
    }

    static func progressFraction(
        phase: LauncherPhase,
        totalCount: Int?,
        copiedCount: Int,
        verifiedCount: Int,
        committedCount: Int,
        isSuccess: Bool
    ) -> Double {
        if isSuccess {
            return 1.0
        }

        guard let totalCount, totalCount > 0 else {
            switch phase {
            case .idle:
                return 0.0
            case .scan:
                return 0.05
            case .plan:
                return 0.18
            case .copy:
                return 0.35
            case .verify:
                return 0.65
            case .commit:
                return 0.85
            case .finalize, .finished:
                return 0.97
            }
        }

        let total = Double(totalCount)
        let copied = min(max(Double(copiedCount), 0), total)
        let verified = min(max(Double(verifiedCount), 0), total)
        let committed = min(max(Double(committedCount), 0), total)

        switch phase {
        case .idle:
            return 0.0
        case .scan:
            return 0.08
        case .plan:
            return 0.18
        case .copy:
            return 0.18 + (copied / total) * 0.47
        case .verify:
            return 0.65 + (verified / total) * 0.20
        case .commit:
            return 0.85 + (committed / total) * 0.13
        case .finalize, .finished:
            return 0.98
        }
    }

    static func estimatedRemainingText(
        now: Date,
        runStartedAt: Date?,
        phase: LauncherPhase,
        copiedCount: Int,
        progressFraction: Double
    ) -> String {
        guard let runStartedAt else {
            return "Estimating time remaining"
        }

        guard copiedCount > 0, phase != .scan else {
            return "Estimating time remaining"
        }

        let elapsed = now.timeIntervalSince(runStartedAt)
        guard elapsed > 0, progressFraction > 0.02, progressFraction < 0.995 else {
            return "Estimating time remaining"
        }

        let remainingSeconds = elapsed * ((1 - progressFraction) / progressFraction)
        return "About \(durationText(seconds: remainingSeconds)) remaining"
    }

    static func completionDurationText(milliseconds: Int) -> String {
        let seconds = Double(max(milliseconds, 0)) / 1_000.0
        let rounded = max(0, Int(seconds.rounded()))
        let minutes = rounded / 60
        let leftoverSeconds = rounded % 60

        if minutes == 0 {
            return "Elapsed time \(leftoverSeconds)s"
        }

        return String(format: "Elapsed time %dm %02ds", minutes, leftoverSeconds)
    }

    private static func durationText(seconds: TimeInterval) -> String {
        let rounded = max(0, Int(seconds.rounded()))
        if rounded < 5 {
            return "a few seconds"
        }
        if rounded < 60 {
            return "\(rounded) seconds"
        }
        let minutes = rounded / 60
        let leftoverSeconds = rounded % 60
        if minutes >= 60 {
            let hours = minutes / 60
            let leftoverMinutes = minutes % 60
            if leftoverMinutes == 0 {
                return hours == 1 ? "1 hour" : "\(hours) hours"
            }
            return "\(hours)h \(leftoverMinutes)m"
        }
        if leftoverSeconds < 10 {
            return minutes == 1 ? "1 minute" : "\(minutes) minutes"
        }
        return "\(minutes)m \(leftoverSeconds)s"
    }
}

struct LauncherPathValidation {
    static func isValidSourcePath(_ path: String) -> Bool {
        isReadableDirectory(path)
    }

    static func isValidDestinationPath(_ path: String) -> Bool {
        guard isDirectory(path) else {
            return false
        }

        return FileManager.default.isWritableFile(atPath: path)
    }

    static func isValidPathPair(sourcePath: String, destinationPath: String) -> Bool {
        guard isValidSourcePath(sourcePath), isValidDestinationPath(destinationPath) else {
            return false
        }

        return DirectoryPathOverlapValidator.analyze(
            sourcePath: sourcePath,
            destinationPath: destinationPath
        ).isDisjoint
    }

    static func invalidPathPairMessage(sourcePath: String, destinationPath: String) -> String? {
        guard isValidSourcePath(sourcePath), isValidDestinationPath(destinationPath) else {
            return nil
        }

        let analysis = DirectoryPathOverlapValidator.analyze(
            sourcePath: sourcePath,
            destinationPath: destinationPath
        )
        guard !analysis.isDisjoint else {
            return nil
        }

        return "Source and destination must be different folders with no nesting."
    }

    private static func isReadableDirectory(_ path: String) -> Bool {
        guard isDirectory(path) else {
            return false
        }

        return FileManager.default.isReadableFile(atPath: path)
    }

    private static func isDirectory(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
        return exists && isDirectory.boolValue
    }
}

struct RollkeepCLIExecutableLocator {
    static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        launcherExecutableURL: URL? = Bundle.main.executableURL
    ) -> URL? {
        if let launcherExecutableURL {
            let sibling = launcherExecutableURL
                .deletingLastPathComponent()
                .appendingPathComponent("rollkeep", isDirectory: false)
            if isExecutable(path: sibling.path) {
                return sibling
            }
            return nil
        }

        if let override = environment["ROLLKEEP_CLI_PATH"],
           isExecutable(path: override) {
            return URL(fileURLWithPath: override)
        }

        if let pathValue = environment["PATH"] {
            for directory in pathValue.split(separator: ":").map(String.init) {
                let candidate = URL(fileURLWithPath: directory, isDirectory: true)
                    .appendingPathComponent("rollkeep", isDirectory: false)
                if isExecutable(path: candidate.path) {
                    return candidate
                }
            }
        }

        let fallbackCandidates = [
            "/opt/homebrew/bin/rollkeep",
            "/usr/local/bin/rollkeep",
            "/usr/bin/rollkeep",
        ]

        for candidate in fallbackCandidates where isExecutable(path: candidate) {
            return URL(fileURLWithPath: candidate)
        }

        return nil
    }

    private static func isExecutable(path: String) -> Bool {
        !path.isEmpty && FileManager.default.isExecutableFile(atPath: path)
    }
}
