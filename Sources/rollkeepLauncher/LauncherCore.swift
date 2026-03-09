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
