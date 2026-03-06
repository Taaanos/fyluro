import ArgumentParser
import Foundation

struct RollkeepCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rollkeep",
        abstract: "Safely ingest media from a source path into a destination library.",
        discussion: "Current MVP status: source scan implementation with receipt logging."
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
        let sessionID = UUID().uuidString.lowercased()
        let sourceURL = URL(fileURLWithPath: source, isDirectory: true).standardizedFileURL
        let destURL = URL(fileURLWithPath: dest, isDirectory: true).standardizedFileURL

        let receiptWriter = try ReceiptWriter(destRoot: destURL, sessionID: sessionID)

        logger.info("command_started", metadata: [
            "session_id": sessionID,
            "source": sourceURL.path,
            "dest": destURL.path,
            "dry_run": dryRun.description,
            "config": config ?? "",
            "receipt_path": receiptWriter.sink.path,
            "receipt_sink": receiptWriter.sink.kind.rawValue,
        ])

        try receiptWriter.append(eventType: "SESSION_STARTED", phase: .scan, data: [
            "source": sourceURL.path,
            "destination": destURL.path,
            "dry_run": dryRun,
            "receipt_path": receiptWriter.sink.path,
            "receipt_sink": receiptWriter.sink.kind.rawValue,
        ])

        if let config {
            logger.warn("config_not_implemented", metadata: ["path": config])
        }

        let scanner = SourceScanner()

        do {
            let summary = try scanner.scan(sourceRoot: sourceURL)

            for errorRecord in summary.errors {
                logger.error("scan_file_error", metadata: [
                    "session_id": sessionID,
                    "path": errorRecord.path,
                    "error": errorRecord.message,
                ])

                try receiptWriter.append(eventType: "ERROR", phase: .scan, data: [
                    "path": errorRecord.path,
                    "error": errorRecord.message,
                ])
            }

            try receiptWriter.append(eventType: "SCAN_SUMMARY", phase: .scan, data: [
                "photos": ["count": summary.photoCount, "bytes": summary.photoBytes],
                "videos": ["count": summary.videoCount, "bytes": summary.videoBytes],
                "candidate_count": summary.candidates.count,
                "typical_location_count": summary.filesInTypicalLocations,
                "outside_typical_location_count": summary.filesOutsideTypicalLocations,
                "error_count": summary.errors.count,
            ])

            let isoFormatter = ISO8601DateFormatter()
            let orderedFiles = summary.candidates.map { candidate in
                [
                    "path": candidate.relativePath,
                    "media_type": candidate.mediaType.rawValue,
                    "size_bytes": candidate.sizeBytes,
                    "mtime": isoFormatter.string(from: candidate.mtime),
                ] as [String: Any]
            }

            try receiptWriter.append(eventType: "SCAN_FILE_LIST", phase: .scan, data: [
                "files": orderedFiles,
            ])

            logger.info("scan_summary", metadata: [
                "session_id": sessionID,
                "photo_count": String(summary.photoCount),
                "video_count": String(summary.videoCount),
                "photo_bytes": String(summary.photoBytes),
                "video_bytes": String(summary.videoBytes),
                "candidate_count": String(summary.candidates.count),
                "typical_location_count": String(summary.filesInTypicalLocations),
                "outside_typical_location_count": String(summary.filesOutsideTypicalLocations),
                "error_count": String(summary.errors.count),
            ])

            if dryRun {
                logger.info("dry_run_complete", metadata: ["note": "scan completed; no files copied"])
            } else {
                logger.warn("ingest_not_implemented_after_scan", metadata: ["next_phase": "plan"])
            }

            try receiptWriter.append(eventType: "SESSION_FINISHED", phase: .finalize, data: [
                "status": "scan_complete",
                "dry_run": dryRun,
                "candidate_count": summary.candidates.count,
                "error_count": summary.errors.count,
            ])
        } catch let error as SourceScannerError {
            let message: String
            switch error {
            case .unreadableSourceRoot(let path):
                message = "Source root unreadable: \(path)"
            }

            logger.error("scan_failed", metadata: [
                "session_id": sessionID,
                "error": message,
            ])

            try receiptWriter.append(eventType: "ERROR", phase: .scan, data: [
                "error": message,
            ])

            try receiptWriter.append(eventType: "SESSION_FINISHED", phase: .finalize, data: [
                "status": "failed",
                "failure_phase": IngestPhase.scan.rawValue,
                "error": message,
            ])

            throw ExitCode.failure
        }
    }
}

RollkeepCLI.main()
