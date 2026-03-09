import ArgumentParser
import Foundation

struct RollkeepCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rollkeep",
        abstract: "Safely ingest media from a source path into a destination library.",
        discussion: "Current MVP status: scan + plan + staging copy with optional read-back verification; commit is still pending."
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

    @Flag(name: .long, help: "Disable read-back hash verification after staging copy.")
    var skipVerify = false

    @Option(name: .long, help: "Maximum number of files copied to staging in parallel.")
    var maxParallelCopies = 2

    @Option(name: .long, help: "Optional config file path (reserved for a later subissue).")
    var config: String?

    mutating func validate() throws {
        if maxParallelCopies < 1 {
            throw ValidationError("--max-parallel-copies must be at least 1")
        }
    }

    mutating func run() throws {
        let logger = StructuredLogger(verbose: verbose)
        let sessionID = UUID().uuidString.lowercased()
        let sourceURL = URL(fileURLWithPath: source, isDirectory: true).standardizedFileURL
        let destURL = URL(fileURLWithPath: dest, isDirectory: true).standardizedFileURL
        let verificationEnabled = !skipVerify

        let receiptWriter = try ReceiptWriter(destRoot: destURL, sessionID: sessionID)
        let scanner = SourceScanner()
        let cameraLabeler = CameraLabeler()
        let isoFormatter = ISO8601DateFormatter()

        var finalStatus = "completed"
        var failurePhase = IngestPhase.finalize
        var failureReason: String?
        var scanSummary: ScanSummary?
        var destinationPlan: DestinationPathPlanner.Plan?
        var cardAssessment: CameraCardAssessment?
        var touchedPaths = ReceiptTouchedPaths()
        var outcomeTotals = ReceiptOutcomeTotals()
        var markdownSummaryPath: String?
        var copyStageCompleted = false

        touchedPaths.addWrittenReceiptFile(receiptWriter.sink.path)

        logger.info("command_started", metadata: [
            "session_id": sessionID,
            "source": sourceURL.path,
            "dest": destURL.path,
            "dry_run": dryRun.description,
            "md": md.description,
            "verify_after_copy": verificationEnabled.description,
            "max_parallel_copies": String(maxParallelCopies),
            "config": config ?? "",
            "receipt_path": receiptWriter.sink.path,
            "receipt_sink": receiptWriter.sink.kind.rawValue,
        ])

        try receiptWriter.append(eventType: .sessionStarted, phase: .scan, data: [
            "source": sourceURL.path,
            "destination": destURL.path,
            "dry_run": dryRun,
            "markdown_summary_requested": md,
            "verify_after_copy": verificationEnabled,
            "max_parallel_copies": maxParallelCopies,
            "receipt_path": receiptWriter.sink.path,
            "receipt_sink": receiptWriter.sink.kind.rawValue,
        ])

        if let config {
            logger.warn("config_not_implemented", metadata: ["path": config])
        }

        do {
            let summary = try scanner.scan(sourceRoot: sourceURL)
            scanSummary = summary

            for errorRecord in summary.errors {
                outcomeTotals.errors += 1
                logger.error("scan_file_error", metadata: [
                    "session_id": sessionID,
                    "path": errorRecord.path,
                    "error": errorRecord.message,
                ])

                try receiptWriter.append(eventType: .error, phase: .scan, data: [
                    "path": errorRecord.path,
                    "error": errorRecord.message,
                ])
            }

            try receiptWriter.append(eventType: .scanSummary, phase: .scan, data: [
                "photos": ["count": summary.photoCount, "bytes": summary.photoBytes],
                "videos": ["count": summary.videoCount, "bytes": summary.videoBytes],
                "candidate_count": summary.candidates.count,
                "typical_location_count": summary.filesInTypicalLocations,
                "outside_typical_location_count": summary.filesOutsideTypicalLocations,
                "error_count": summary.errors.count,
            ])

            let cameraInferences = summary.candidates.map { candidate in
                (candidate.absolutePath, cameraLabeler.infer(for: candidate))
            }
            let cameraInferenceByPath = Dictionary(uniqueKeysWithValues: cameraInferences)
            let plannerInputs = summary.candidates.map { candidate in
                let inference = cameraInferenceByPath[candidate.absolutePath] ?? CameraInference(
                    cameraLabel: "unknown-camera",
                    confidence: 0.2,
                    make: nil,
                    model: nil,
                    serial: nil
                )
                return DestinationPathPlanner.SourceFile(
                    candidate: candidate,
                    cameraLabel: inference.cameraLabel,
                    sourceHash: nil
                )
            }

            let plan = DestinationPathPlanner().plan(
                destRoot: destURL,
                sessionID: sessionID,
                files: plannerInputs
            )
            destinationPlan = plan

            let assessment = cameraLabeler.assessCard(candidates: summary.candidates)
            cardAssessment = assessment

            let cameraDistribution = assessment.distribution.map { entry in
                [
                    "camera_label": entry.cameraLabel,
                    "file_count": entry.fileCount,
                    "avg_confidence": entry.averageConfidence,
                ] as [String: Any]
            }

            var cameraDetectedData: [String: Any] = [
                "camera_label": assessment.cameraLabel,
                "confidence": assessment.confidence,
                "mixed_camera_detected": assessment.mixedCameraDetected,
                "sample_size": assessment.sampleSize,
                "total_candidates": assessment.totalCandidates,
                "labels": cameraDistribution,
            ]
            if let warning = assessment.warning {
                cameraDetectedData["warning"] = warning
            }
            try receiptWriter.append(eventType: .cameraLabelDetected, phase: .scan, data: cameraDetectedData)

            let plannedFilesForReceipt = plan.files.map { planned -> [String: Any] in
                var entry: [String: Any] = [
                    "path": planned.candidate.relativePath,
                    "media_type": planned.candidate.mediaType.rawValue,
                    "camera_label": planned.cameraLabel,
                    "final_path": planned.finalPath,
                    "outcome": planned.disposition.rawValue,
                    "collision_renamed": planned.collisionResolved,
                ]
                if let stagingPath = planned.stagingPath {
                    entry["staging_path"] = stagingPath
                }
                if let collisionSuffix = planned.collisionSuffix {
                    entry["collision_suffix"] = collisionSuffix
                }
                if let duplicateOfPath = planned.duplicateOfPath {
                    entry["duplicate_of_path"] = duplicateOfPath
                }
                return entry
            }

            try receiptWriter.append(eventType: .planComputed, phase: .plan, data: [
                "planned_file_count": plan.files.count,
                "directories_to_create": plan.directoriesToCreate,
                "directories_to_create_count": plan.directoriesToCreate.count,
                "duplicate_not_copied_count": plan.duplicatesSkipped,
                "conflicts_renamed_count": plan.conflictsRenamed,
                "files": plannedFilesForReceipt,
            ])

            for directoryPath in plan.directoriesToCreate {
                touchedPaths.addCreatedDirectory(directoryPath)
                try receiptWriter.append(eventType: .dirCreated, phase: .plan, data: [
                    "path": directoryPath,
                    "status": "planned",
                ])
            }

            var copyJobs: [StagingCopyEngine.FileJob] = []

            for planned in plan.files {
                if planned.collisionResolved {
                    outcomeTotals.conflictsRenamed += 1
                    try receiptWriter.append(eventType: .conflictRenamed, phase: .plan, data: [
                        "path": planned.candidate.relativePath,
                        "source_path": planned.candidate.absolutePath,
                        "final_path": planned.finalPath,
                        "collision_suffix": planned.collisionSuffix ?? 0,
                        "status": "planned",
                    ])
                }

                switch planned.disposition {
                case .duplicateNotCopied:
                    outcomeTotals.duplicateNotCopied += 1
                    touchedPaths.addPlannedFinalFile(planned.finalPath)

                    try receiptWriter.append(eventType: .duplicateSkipped, phase: .plan, data: [
                        "path": planned.candidate.relativePath,
                        "source_path": planned.candidate.absolutePath,
                        "final_path": planned.finalPath,
                        "duplicate_of_path": planned.duplicateOfPath ?? planned.finalPath,
                        "outcome": planned.disposition.rawValue,
                    ])

                    try receiptWriter.append(eventType: .fileCommitted, phase: .plan, data: [
                        "path": planned.candidate.relativePath,
                        "source_path": planned.candidate.absolutePath,
                        "final_path": planned.finalPath,
                        "outcome": planned.disposition.rawValue,
                        "status": "skipped_duplicate",
                        "executed": false,
                    ])
                case .stageAndCommit:
                    outcomeTotals.plannedStageAndCommit += 1
                    guard let stagingPath = planned.stagingPath else {
                        continue
                    }

                    touchedPaths.addPlannedStagingFile(stagingPath)
                    touchedPaths.addPlannedFinalFile(planned.finalPath)
                    touchedPaths.addPlannedMove(from: stagingPath, to: planned.finalPath)

                    copyJobs.append(StagingCopyEngine.FileJob(
                        relativePath: planned.candidate.relativePath,
                        sourcePath: planned.candidate.absolutePath,
                        stagingPath: stagingPath,
                        finalPath: planned.finalPath,
                        expectedBytes: planned.candidate.sizeBytes
                    ))

                    if dryRun {
                        try receiptWriter.append(eventType: .fileCopyStarted, phase: .copy, data: [
                            "path": planned.candidate.relativePath,
                            "source_path": planned.candidate.absolutePath,
                            "staging_path": stagingPath,
                            "final_path": planned.finalPath,
                            "status": "planned",
                            "executed": false,
                        ])

                        try receiptWriter.append(eventType: .fileCopied, phase: .copy, data: [
                            "path": planned.candidate.relativePath,
                            "source_path": planned.candidate.absolutePath,
                            "staging_path": stagingPath,
                            "final_path": planned.finalPath,
                            "outcome": "planned_for_copy",
                            "executed": false,
                        ])

                        try receiptWriter.append(eventType: .fileVerifyStarted, phase: .verify, data: [
                            "path": planned.candidate.relativePath,
                            "source_path": planned.candidate.absolutePath,
                            "staging_path": stagingPath,
                            "status": "planned",
                            "executed": false,
                        ])

                        try receiptWriter.append(eventType: .fileVerified, phase: .verify, data: [
                            "path": planned.candidate.relativePath,
                            "source_path": planned.candidate.absolutePath,
                            "staging_path": stagingPath,
                            "outcome": "pending",
                            "executed": false,
                        ])
                    }

                    try receiptWriter.append(eventType: .fileCommitStarted, phase: .commit, data: [
                        "path": planned.candidate.relativePath,
                        "source_path": planned.candidate.absolutePath,
                        "staging_path": stagingPath,
                        "final_path": planned.finalPath,
                        "status": "planned",
                        "executed": false,
                    ])

                    try receiptWriter.append(eventType: .fileCommitted, phase: .commit, data: [
                        "path": planned.candidate.relativePath,
                        "source_path": planned.candidate.absolutePath,
                        "staging_path": stagingPath,
                        "final_path": planned.finalPath,
                        "outcome": planned.disposition.rawValue,
                        "status": "planned",
                        "executed": false,
                    ])
                }
            }

            if assessment.mixedCameraDetected {
                logger.warn("mixed_camera_card_detected", metadata: [
                    "session_id": sessionID,
                    "camera_label": assessment.cameraLabel,
                    "confidence": String(format: "%.2f", assessment.confidence),
                ])
            }

            let plannedBySourcePath = Dictionary(uniqueKeysWithValues: plan.files.map { planned in
                (planned.candidate.absolutePath, planned)
            })

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
                let plannedFile = plannedBySourcePath[candidate.absolutePath]
                fileData["camera_label"] = inference.cameraLabel
                fileData["confidence"] = inference.confidence
                fileData["final_path"] = plannedFile?.finalPath ?? "missing"
                fileData["staging_path"] = plannedFile?.stagingPath ?? "duplicate_not_copied"
                fileData["plan_outcome"] = plannedFile?.disposition.rawValue ?? "missing"
                fileData["collision_renamed"] = plannedFile?.collisionResolved ?? false

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

                try receiptWriter.append(eventType: .videoMetadataFallbackUsed, phase: .scan, data: [
                    "path": candidate.relativePath,
                    "capture_datetime": isoFormatter.string(from: videoMetadata.captureDateTime),
                    "capture_datetime_source": videoMetadata.captureDateSource.rawValue,
                ])
            }

            try receiptWriter.append(eventType: .scanFileList, phase: .scan, data: [
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

            logger.info("plan_summary", metadata: [
                "session_id": sessionID,
                "planned_file_count": String(plan.files.count),
                "directories_to_create_count": String(plan.directoriesToCreate.count),
                "duplicate_not_copied_count": String(plan.duplicatesSkipped),
                "conflicts_renamed_count": String(plan.conflictsRenamed),
            ])

            if dryRun {
                logger.info("dry_run_complete", metadata: ["note": "scan+plan completed; no files copied"])
            } else {
                for job in copyJobs {
                    try receiptWriter.append(eventType: .fileCopyStarted, phase: .copy, data: [
                        "path": job.relativePath,
                        "source_path": job.sourcePath,
                        "staging_path": job.stagingPath,
                        "final_path": job.finalPath,
                        "expected_bytes": job.expectedBytes,
                        "verification_enabled": verificationEnabled,
                        "status": "queued",
                        "executed": true,
                    ])
                }

                let copyEngine = StagingCopyEngine(configuration: .init(
                    verifyAfterCopy: verificationEnabled,
                    maxParallelCopies: maxParallelCopies
                ))

                let copyResults: [StagingCopyEngine.FileResult]
                do {
                    copyResults = try copyEngine.copyToStaging(files: copyJobs)
                } catch let engineError as StagingCopyEngine.EngineError {
                    switch engineError {
                    case .invalidConfiguration(let message):
                        throw IngestRuntimeError(phase: .copy, message: message)
                    case .runFailed(let partialResults, let failure):
                        try appendCopyResults(
                            partialResults,
                            verificationEnabled: verificationEnabled,
                            receiptWriter: receiptWriter,
                            touchedPaths: &touchedPaths,
                            outcomeTotals: &outcomeTotals
                        )
                        try appendCopyFailure(
                            failure,
                            receiptWriter: receiptWriter,
                            touchedPaths: &touchedPaths,
                            outcomeTotals: &outcomeTotals
                        )

                        let message = "Failed during \(failure.phase.rawValue) for \(failure.relativePath): \(failure.message)"
                        throw IngestRuntimeError(
                            phase: failure.phase,
                            message: message,
                            receiptErrorRecorded: true
                        )
                    }
                }

                try appendCopyResults(
                    copyResults,
                    verificationEnabled: verificationEnabled,
                    receiptWriter: receiptWriter,
                    touchedPaths: &touchedPaths,
                    outcomeTotals: &outcomeTotals
                )
                copyStageCompleted = true

                logger.info("copy_stage_completed", metadata: [
                    "session_id": sessionID,
                    "copied_count": String(outcomeTotals.copied),
                    "verified_count": String(outcomeTotals.verified),
                    "verification_skipped_count": String(outcomeTotals.verificationSkipped),
                ])
                logger.warn("commit_not_implemented_after_copy", metadata: ["next_phase": "commit"])
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

                    markdownSummaryPath = markdownURL.path
                    touchedPaths.addWrittenReceiptFile(markdownURL.path)

                    logger.info("receipt_markdown_written", metadata: [
                        "session_id": sessionID,
                        "path": markdownURL.path,
                    ])

                    try receiptWriter.append(eventType: .receiptMarkdownWritten, phase: .finalize, data: [
                        "path": markdownURL.path,
                    ])
                } catch {
                    outcomeTotals.errors += 1
                    let message = "Markdown receipt write failed: \(error.localizedDescription)"
                    logger.warn("receipt_markdown_write_failed", metadata: [
                        "session_id": sessionID,
                        "error": message,
                    ])
                    try receiptWriter.append(eventType: .error, phase: .finalize, data: [
                        "error": message,
                    ])
                }
            }
        } catch {
            finalStatus = "aborted"
            let context = failureContext(from: error)
            failurePhase = context.phase
            failureReason = context.message
            outcomeTotals.errors += 1
            let skipGenericReceiptError = (error as? IngestRuntimeError)?.receiptErrorRecorded ?? false

            logger.error("session_aborted", metadata: [
                "session_id": sessionID,
                "phase": context.phase.rawValue,
                "error": context.message,
            ])

            if !skipGenericReceiptError {
                do {
                    try receiptWriter.append(eventType: .error, phase: context.phase, data: [
                        "error": context.message,
                    ])
                } catch {
                    logger.error("receipt_append_failed_after_abort", metadata: [
                        "session_id": sessionID,
                        "error": error.localizedDescription,
                    ])
                }
            }
        }

        let summaryData = buildSummaryData(
            finalStatus: finalStatus,
            dryRun: dryRun,
            verificationEnabled: verificationEnabled,
            copyStageCompleted: copyStageCompleted,
            scanSummary: scanSummary,
            destinationPlan: destinationPlan,
            cardAssessment: cardAssessment,
            outcomeTotals: outcomeTotals,
            touchedPaths: touchedPaths,
            receiptWriter: receiptWriter,
            markdownSummaryPath: markdownSummaryPath,
            isoFormatter: isoFormatter
        )

        var summaryEventWritten = false
        do {
            try receiptWriter.append(eventType: .summary, phase: .finalize, data: summaryData)
            summaryEventWritten = true
        } catch {
            logger.error("receipt_summary_write_failed", metadata: [
                "session_id": sessionID,
                "error": error.localizedDescription,
            ])
        }

        var finishedData: [String: Any] = [
            "status": finalStatus,
            "dry_run": dryRun,
            "candidate_count": scanSummary?.candidates.count ?? 0,
            "error_count": outcomeTotals.errors,
            "receipt_path": receiptWriter.sink.path,
            "receipt_sink": receiptWriter.sink.kind.rawValue,
            "summary_event_written": summaryEventWritten,
            "resume_hook": receiptWriter.resumeHook(),
        ]

        if let failureReason {
            finishedData["failure_phase"] = failurePhase.rawValue
            finishedData["error"] = failureReason
        }

        do {
            try receiptWriter.append(eventType: .sessionFinished, phase: .finalize, data: finishedData)
        } catch {
            logger.error("receipt_session_finished_write_failed", metadata: [
                "session_id": sessionID,
                "error": error.localizedDescription,
            ])
        }

        if finalStatus == "aborted" {
            throw ExitCode.failure
        }
    }

    private func appendCopyResults(
        _ results: [StagingCopyEngine.FileResult],
        verificationEnabled: Bool,
        receiptWriter: ReceiptWriter,
        touchedPaths: inout ReceiptTouchedPaths,
        outcomeTotals: inout ReceiptOutcomeTotals
    ) throws {
        for result in results {
            outcomeTotals.copied += 1
            touchedPaths.addWrittenStagingFile(result.stagingPath)

            try receiptWriter.append(eventType: .fileCopied, phase: .copy, data: [
                "path": result.relativePath,
                "source_path": result.sourcePath,
                "staging_path": result.stagingPath,
                "final_path": result.finalPath,
                "bytes": result.bytesCopied,
                "hash_sha256": result.sourceHashSHA256,
                "status": "copied_to_staging",
                "executed": true,
            ])

            let verifyStartStatus = verificationEnabled ? "started" : "skipped_disabled"
            try receiptWriter.append(eventType: .fileVerifyStarted, phase: .verify, data: [
                "path": result.relativePath,
                "source_path": result.sourcePath,
                "staging_path": result.stagingPath,
                "status": verifyStartStatus,
                "executed": true,
            ])

            if result.verificationSkipped {
                outcomeTotals.verificationSkipped += 1
                try receiptWriter.append(eventType: .fileVerified, phase: .verify, data: [
                    "path": result.relativePath,
                    "source_path": result.sourcePath,
                    "staging_path": result.stagingPath,
                    "outcome": "skipped",
                    "status": "verification_disabled",
                    "hash_sha256_source": result.sourceHashSHA256,
                    "executed": true,
                ])
            } else {
                outcomeTotals.verified += 1
                try receiptWriter.append(eventType: .fileVerified, phase: .verify, data: [
                    "path": result.relativePath,
                    "source_path": result.sourcePath,
                    "staging_path": result.stagingPath,
                    "outcome": "verified",
                    "status": "verified",
                    "hash_sha256_source": result.sourceHashSHA256,
                    "hash_sha256_staging": result.verifiedHashSHA256 ?? "missing",
                    "hash_match": result.sourceHashSHA256 == (result.verifiedHashSHA256 ?? ""),
                    "bytes": result.bytesCopied,
                    "executed": true,
                ])
            }
        }
    }

    private func appendCopyFailure(
        _ failure: StagingCopyEngine.FileFailure,
        receiptWriter: ReceiptWriter,
        touchedPaths: inout ReceiptTouchedPaths,
        outcomeTotals: inout ReceiptOutcomeTotals
    ) throws {
        var copiedData: [String: Any] = [
            "path": failure.relativePath,
            "source_path": failure.sourcePath,
            "staging_path": failure.stagingPath,
            "final_path": failure.finalPath,
            "executed": true,
        ]

        if let expectedBytes = failure.expectedBytes {
            copiedData["expected_bytes"] = expectedBytes
        }
        if let actualBytes = failure.actualBytes {
            copiedData["bytes"] = actualBytes
        }
        if let expectedHash = failure.expectedHashSHA256 {
            copiedData["hash_sha256"] = expectedHash
        }

        switch failure.phase {
        case .verify:
            outcomeTotals.copied += 1
            touchedPaths.addWrittenStagingFile(failure.stagingPath)

            copiedData["status"] = "copied_to_staging"
            copiedData["outcome"] = "copied_to_staging"
            try receiptWriter.append(eventType: .fileCopied, phase: .copy, data: copiedData)

            try receiptWriter.append(eventType: .fileVerifyStarted, phase: .verify, data: [
                "path": failure.relativePath,
                "source_path": failure.sourcePath,
                "staging_path": failure.stagingPath,
                "status": "started",
                "executed": true,
            ])

            var verifyData: [String: Any] = [
                "path": failure.relativePath,
                "source_path": failure.sourcePath,
                "staging_path": failure.stagingPath,
                "outcome": "failed",
                "status": "failed",
                "error": failure.message,
                "executed": true,
            ]
            if let expectedBytes = failure.expectedBytes {
                verifyData["expected_bytes"] = expectedBytes
            }
            if let actualBytes = failure.actualBytes {
                verifyData["bytes"] = actualBytes
            }
            if let expectedHash = failure.expectedHashSHA256 {
                verifyData["hash_sha256_source"] = expectedHash
            }
            if let actualHash = failure.actualHashSHA256 {
                verifyData["hash_sha256_staging"] = actualHash
                verifyData["hash_match"] = failure.expectedHashSHA256 == actualHash
            }

            try receiptWriter.append(eventType: .fileVerified, phase: .verify, data: verifyData)
        case .copy:
            copiedData["status"] = "failed"
            copiedData["outcome"] = "copy_failed"
            copiedData["error"] = failure.message
            try receiptWriter.append(eventType: .fileCopied, phase: .copy, data: copiedData)
        case .scan, .plan, .commit, .finalize:
            break
        }

        var errorData: [String: Any] = [
            "path": failure.relativePath,
            "source_path": failure.sourcePath,
            "staging_path": failure.stagingPath,
            "final_path": failure.finalPath,
            "error": failure.message,
        ]
        if let expectedBytes = failure.expectedBytes {
            errorData["expected_bytes"] = expectedBytes
        }
        if let actualBytes = failure.actualBytes {
            errorData["bytes"] = actualBytes
        }
        if let expectedHash = failure.expectedHashSHA256 {
            errorData["hash_sha256_source"] = expectedHash
        }
        if let actualHash = failure.actualHashSHA256 {
            errorData["hash_sha256_staging"] = actualHash
        }

        try receiptWriter.append(eventType: .error, phase: failure.phase, data: errorData)
    }

    private func failureContext(from error: Error) -> FailureContext {
        if let sourceError = error as? SourceScannerError {
            switch sourceError {
            case .unreadableSourceRoot(let path):
                return FailureContext(
                    phase: .scan,
                    message: "Source root unreadable: \(path)"
                )
            }
        }

        if let ingestError = error as? IngestRuntimeError {
            return FailureContext(
                phase: ingestError.phase,
                message: ingestError.message
            )
        }

        return FailureContext(
            phase: .finalize,
            message: error.localizedDescription
        )
    }

    private func buildSummaryData(
        finalStatus: String,
        dryRun: Bool,
        verificationEnabled: Bool,
        copyStageCompleted: Bool,
        scanSummary: ScanSummary?,
        destinationPlan: DestinationPathPlanner.Plan?,
        cardAssessment: CameraCardAssessment?,
        outcomeTotals: ReceiptOutcomeTotals,
        touchedPaths: ReceiptTouchedPaths,
        receiptWriter: ReceiptWriter,
        markdownSummaryPath: String?,
        isoFormatter: ISO8601DateFormatter
    ) -> [String: Any] {
        let candidates = scanSummary?.candidates ?? []
        let dateRange = buildDateRange(candidates: candidates, formatter: isoFormatter)

        let cameraLabels = cardAssessment?.distribution.map { entry in
            [
                "label": entry.cameraLabel,
                "confidence": entry.averageConfidence,
                "file_count": entry.fileCount,
            ] as [String: Any]
        } ?? []

        let perFileOutcomes = destinationPlan?.files.map { planned in
            var payload: [String: Any] = [
                "path": planned.candidate.relativePath,
                "source_path": planned.candidate.absolutePath,
                "media_type": planned.candidate.mediaType.rawValue,
                "outcome": planned.disposition.rawValue,
                "final_path": planned.finalPath,
                "executed": false,
            ]

            if let stagingPath = planned.stagingPath {
                payload["staging_path"] = stagingPath
            }
            if let duplicateOfPath = planned.duplicateOfPath {
                payload["duplicate_of_path"] = duplicateOfPath
            }
            if let collisionSuffix = planned.collisionSuffix {
                payload["collision_suffix"] = collisionSuffix
            }

            return payload
        } ?? []

        return [
            "status": finalStatus,
            "verified_ok": copyStageCompleted && verificationEnabled && outcomeTotals.copied == outcomeTotals.verified,
            "dry_run": dryRun,
            "verification_enabled": verificationEnabled,
            "totals_by_media_type": [
                "photos": scanSummary?.photoCount ?? 0,
                "videos": scanSummary?.videoCount ?? 0,
            ],
            "totals_by_outcome": [
                "copied": outcomeTotals.copied,
                "verified": outcomeTotals.verified,
                "verification_skipped": outcomeTotals.verificationSkipped,
                "duplicate_not_copied": outcomeTotals.duplicateNotCopied,
                "conflicts_renamed": outcomeTotals.conflictsRenamed,
                "errors": outcomeTotals.errors,
                "planned_stage_and_commit": outcomeTotals.plannedStageAndCommit,
            ],
            "bytes_processed": (scanSummary?.photoBytes ?? 0) + (scanSummary?.videoBytes ?? 0),
            "date_range": dateRange,
            "camera_labels": cameraLabels,
            "receipt_paths": receiptWriter.receiptPaths.map { ["kind": $0.kind.rawValue, "path": $0.path] },
            "receipt_sink_transitions": receiptWriter.sinkTransitions.map(\.payload),
            "touched_paths": touchedPaths.payload(with: receiptWriter),
            "planned_file_count": destinationPlan?.files.count ?? 0,
            "per_file_outcomes": perFileOutcomes,
            "markdown_summary_path": markdownSummaryPath ?? "not_written",
            "resume_hook": receiptWriter.resumeHook(),
        ]
    }

    private func buildDateRange(candidates: [MediaCandidate], formatter: ISO8601DateFormatter) -> [String: Any] {
        guard !candidates.isEmpty else {
            return ["start": "unknown", "end": "unknown"]
        }

        let dates = candidates.map(captureDateForSummary(_:))
        guard let start = dates.min(), let end = dates.max() else {
            return ["start": "unknown", "end": "unknown"]
        }

        return [
            "start": formatter.string(from: start),
            "end": formatter.string(from: end),
        ]
    }

    private func captureDateForSummary(_ candidate: MediaCandidate) -> Date {
        if let photoDate = candidate.photoMetadata?.captureDateTime {
            return photoDate
        }

        if let videoDate = candidate.videoMetadata?.captureDateTime {
            return videoDate
        }

        return candidate.mtime
    }
}

private struct FailureContext {
    let phase: IngestPhase
    let message: String
}

private struct IngestRuntimeError: Error {
    let phase: IngestPhase
    let message: String
    let receiptErrorRecorded: Bool

    init(phase: IngestPhase, message: String, receiptErrorRecorded: Bool = false) {
        self.phase = phase
        self.message = message
        self.receiptErrorRecorded = receiptErrorRecorded
    }
}

private struct ReceiptOutcomeTotals {
    var copied = 0
    var verified = 0
    var verificationSkipped = 0
    var duplicateNotCopied = 0
    var conflictsRenamed = 0
    var errors = 0
    var plannedStageAndCommit = 0
}

private struct FileMove: Hashable {
    let fromPath: String
    let toPath: String

    var payload: [String: String] {
        [
            "from": fromPath,
            "to": toPath,
        ]
    }
}

private struct ReceiptTouchedPaths {
    private var createdDirectories: Set<String> = []
    private var writtenStagingFiles: Set<String> = []
    private var writtenFinalFiles: Set<String> = []
    private var moveOperations: Set<FileMove> = []
    private var deletedPaths: Set<String> = []

    private var plannedStagingFiles: Set<String> = []
    private var plannedFinalFiles: Set<String> = []
    private var plannedMoveOperations: Set<FileMove> = []

    private var writtenReceiptFiles: Set<String> = []

    mutating func addCreatedDirectory(_ path: String) {
        createdDirectories.insert(path)
    }

    mutating func addWrittenStagingFile(_ path: String) {
        writtenStagingFiles.insert(path)
    }

    mutating func addWrittenFinalFile(_ path: String) {
        writtenFinalFiles.insert(path)
    }

    mutating func addMove(from: String, to: String) {
        moveOperations.insert(FileMove(fromPath: from, toPath: to))
    }

    mutating func addDeletedPath(_ path: String) {
        deletedPaths.insert(path)
    }

    mutating func addPlannedStagingFile(_ path: String) {
        plannedStagingFiles.insert(path)
    }

    mutating func addPlannedFinalFile(_ path: String) {
        plannedFinalFiles.insert(path)
    }

    mutating func addPlannedMove(from: String, to: String) {
        plannedMoveOperations.insert(FileMove(fromPath: from, toPath: to))
    }

    mutating func addWrittenReceiptFile(_ path: String) {
        writtenReceiptFiles.insert(path)
    }

    func payload(with receiptWriter: ReceiptWriter) -> [String: Any] {
        let receiptPaths = Set(receiptWriter.receiptPaths.map(\.path))
        return [
            "created_directories": createdDirectories.sorted(),
            "written_staging_files": writtenStagingFiles.sorted(),
            "written_final_files": writtenFinalFiles.sorted(),
            "move_operations": sortedMoves(moveOperations),
            "deleted_paths": deletedPaths.sorted(),
            "planned_staging_files": plannedStagingFiles.sorted(),
            "planned_final_files": plannedFinalFiles.sorted(),
            "planned_move_operations": sortedMoves(plannedMoveOperations),
            "written_receipt_files": writtenReceiptFiles.union(receiptPaths).sorted(),
        ]
    }

    private func sortedMoves(_ moves: Set<FileMove>) -> [[String: String]] {
        moves
            .sorted { lhs, rhs in
                if lhs.fromPath != rhs.fromPath {
                    return lhs.fromPath < rhs.fromPath
                }
                return lhs.toPath < rhs.toPath
            }
            .map(\.payload)
    }
}

RollkeepCLI.main()
