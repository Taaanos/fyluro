import ArgumentParser
import Foundation

private struct StructuredLogger {
    enum Level: String {
        case debug
        case info
        case warn
        case error
    }

    let verbose: Bool

    func debug(_ message: String, metadata: [String: String] = [:]) {
        guard verbose else { return }
        log(.debug, message: message, metadata: metadata)
    }

    func info(_ message: String, metadata: [String: String] = [:]) {
        log(.info, message: message, metadata: metadata)
    }

    func warn(_ message: String, metadata: [String: String] = [:]) {
        log(.warn, message: message, metadata: metadata)
    }

    private func log(_ level: Level, message: String, metadata: [String: String]) {
        var payload: [String: String] = [
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "level": level.rawValue,
            "message": message,
            "component": "rollkeep-cli",
        ]

        for (key, value) in metadata {
            payload[key] = value
        }

        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
           let line = String(data: data, encoding: .utf8) {
            print(line)
            return
        }

        print("{\"level\":\"\(level.rawValue)\",\"message\":\"\(message)\"}")
    }
}

struct RollkeepCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rollkeep",
        abstract: "Safely ingest media from a source path into a destination library.",
        discussion: "Current MVP status: CLI skeleton with argument parsing and dry-run output."
    )

    @Option(name: .long, help: "Source media path.")
    var source: String

    @Option(name: .long, help: "Destination library path.")
    var dest: String

    @Flag(name: .long, help: "Run planning only; do not write files.")
    var dryRun = false

    @Flag(name: .long, help: "Print verbose diagnostic logs.")
    var verbose = false

    @Option(name: .long, help: "Optional config file path (reserved for a later subissue).")
    var config: String?

    mutating func run() throws {
        let logger = StructuredLogger(verbose: verbose)

        logger.info("command_started", metadata: [
            "source": source,
            "dest": dest,
            "dry_run": dryRun.description,
            "config": config ?? "",
        ])

        if let config {
            logger.warn("config_not_implemented", metadata: ["path": config])
        }

        logger.debug("validated_arguments")

        if dryRun {
            logger.info("dry_run_complete", metadata: ["note": "no files written"])
        } else {
            logger.info("cli_skeleton_ready")
        }
    }
}

RollkeepCLI.main()
