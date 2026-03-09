import Foundation

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
    var stagingPath: String?
    var result: LauncherRunResult?
    var failureReason: String?
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
        case "dry_run_complete", "staging_session_removed", "receipt_markdown_written", "receipt_markdown_write_failed":
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
    var phase: LauncherPhase?
    var plannedStageAndCommit: Int?
    var duplicateNotCopied: Int?
    var copiedIncrement = 0
    var verifiedIncrement = 0
    var committedIncrement = 0
    var errorItem: ReceiptErrorItem?
    var touchedPaths: [String]?
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
        case "FILE_COPIED":
            guard boolValue(from: data["executed"]) != false else {
                return update
            }
            if data["status"] as? String == "copied_to_staging" {
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
            if let touched = data["touched_paths"] as? [String: Any] {
                update.touchedPaths = flattenTouchedPaths(touched)
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
        if let override = environment["ROLLKEEP_CLI_PATH"],
           isExecutable(path: override) {
            return URL(fileURLWithPath: override)
        }

        if let launcherExecutableURL {
            let sibling = launcherExecutableURL
                .deletingLastPathComponent()
                .appendingPathComponent("rollkeep", isDirectory: false)
            if isExecutable(path: sibling.path) {
                return sibling
            }
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
