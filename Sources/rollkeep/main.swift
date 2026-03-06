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

    @Flag(name: .long, help: "Write a human-readable Markdown summary next to the NDJSON receipt.")
    var md = false

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
            "md": md.description,
            "config": config ?? "",
            "receipt_path": receiptWriter.sink.path,
            "receipt_sink": receiptWriter.sink.kind.rawValue,
        ])

        try receiptWriter.append(eventType: "SESSION_STARTED", phase: .scan, data: [
            "source": sourceURL.path,
            "destination": destURL.path,
            "dry_run": dryRun,
            "markdown_summary_requested": md,
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
            let cameraLabeler = CameraLabeler()
            let cameraInferences = summary.candidates.map { candidate in
                (candidate.absolutePath, cameraLabeler.infer(for: candidate))
            }
            let cameraInferenceByPath = Dictionary(uniqueKeysWithValues: cameraInferences)
            let cardAssessment = cameraLabeler.assessCard(candidates: summary.candidates)

            let cameraDistribution = cardAssessment.distribution.map { entry in
                [
                    "camera_label": entry.cameraLabel,
                    "file_count": entry.fileCount,
                    "avg_confidence": entry.averageConfidence,
                ] as [String: Any]
            }

            var cameraDetectedData: [String: Any] = [
                "camera_label": cardAssessment.cameraLabel,
                "confidence": cardAssessment.confidence,
                "mixed_camera_detected": cardAssessment.mixedCameraDetected,
                "sample_size": cardAssessment.sampleSize,
                "total_candidates": cardAssessment.totalCandidates,
                "labels": cameraDistribution,
            ]
            if let warning = cardAssessment.warning {
                cameraDetectedData["warning"] = warning
            }
            try receiptWriter.append(eventType: "CAMERA_LABEL_DETECTED", phase: .scan, data: cameraDetectedData)

            if cardAssessment.mixedCameraDetected {
                logger.warn("mixed_camera_card_detected", metadata: [
                    "session_id": sessionID,
                    "camera_label": cardAssessment.cameraLabel,
                    "confidence": String(format: "%.2f", cardAssessment.confidence),
                ])
            }

            let orderedFiles = summary.candidates.map { candidate in
                var fileData: [String: Any] = [
                    "path": candidate.relativePath,
                    "media_type": candidate.mediaType.rawValue,
                    "size_bytes": candidate.sizeBytes,
                    "mtime": isoFormatter.string(from: candidate.mtime),
                ]
                let inference = cameraInferenceByPath[candidate.absolutePath] ?? CameraInference(
                    cameraLabel: "unknown-camera",
                    confidence: 0.2,
                    make: nil,
                    model: nil,
                    serial: nil
                )
                fileData["camera_label"] = inference.cameraLabel
                fileData["confidence"] = inference.confidence

                if let photoMetadata = candidate.photoMetadata {
                    fileData["capture_datetime"] = photoMetadata.captureDateTime.map(isoFormatter.string(from:)) ?? "missing"
                    fileData["capture_datetime_source"] = photoMetadata.captureDateSource.rawValue
                    fileData["camera_make"] = inference.make ?? "missing"
                    fileData["camera_model"] = inference.model ?? "missing"
                    fileData["camera_serial"] = inference.serial ?? "missing"
                    fileData["plan_bucket"] = photoMetadata.planBucket
                }

                if let videoMetadata = candidate.videoMetadata {
                    fileData["capture_datetime"] = isoFormatter.string(from: videoMetadata.captureDateTime)
                    fileData["capture_datetime_source"] = videoMetadata.captureDateSource.rawValue
                    fileData["capture_datetime_fallback"] = videoMetadata.usedFallback
                    fileData["camera_make"] = inference.make ?? "missing"
                    fileData["camera_model"] = inference.model ?? "missing"
                    fileData["camera_serial"] = inference.serial ?? "missing"
                }

                return fileData
            }

            for candidate in summary.candidates where candidate.mediaType == .video {
                guard let videoMetadata = candidate.videoMetadata, videoMetadata.usedFallback else {
                    continue
                }

                logger.warn("video_creation_time_missing_fallback_to_mtime", metadata: [
                    "session_id": sessionID,
                    "path": candidate.relativePath,
                    "fallback_source": videoMetadata.captureDateSource.rawValue,
                ])

                try receiptWriter.append(eventType: "VIDEO_METADATA_FALLBACK_USED", phase: .scan, data: [
                    "path": candidate.relativePath,
                    "capture_datetime": isoFormatter.string(from: videoMetadata.captureDateTime),
                    "capture_datetime_source": videoMetadata.captureDateSource.rawValue,
                ])
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

            if md {
                do {
                    let markdownURL = try MarkdownReceiptExporter().write(
                        sessionID: sessionID,
                        sourcePath: sourceURL.path,
                        destinationPath: destURL.path,
                        dryRun: dryRun,
                        receiptSink: receiptWriter.sink,
                        summary: summary
                    )

                    logger.info("receipt_markdown_written", metadata: [
                        "session_id": sessionID,
                        "path": markdownURL.path,
                    ])
                    try receiptWriter.append(eventType: "RECEIPT_MARKDOWN_WRITTEN", phase: .finalize, data: [
                        "path": markdownURL.path,
                    ])
                } catch {
                    let message = "Markdown receipt write failed: \(error.localizedDescription)"
                    logger.warn("receipt_markdown_write_failed", metadata: [
                        "session_id": sessionID,
                        "error": message,
                    ])
                    try receiptWriter.append(eventType: "ERROR", phase: .finalize, data: [
                        "error": message,
                    ])
                }
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
