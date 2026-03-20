import ArgumentParser
import Foundation
import RollKeepCore

extension RollkeepCLI {
    mutating func run() throws {
        let pathScheme = try resolvePathScheme()
        let pathSchemeString = pathScheme.receiptPathSchemeString
        let logger = StructuredLogger(verbose: verbose)
        let resolvedPaths = try VolumeResolver(
            explicitSourcePath: source,
            explicitDestinationPath: dest,
            detectTimeoutSeconds: detectTimeoutSeconds,
            forceSourcePicker: pickSource,
            forceDestinationPicker: pickDest,
            logger: logger
        ).resolve()
        let sessionID = UUID().uuidString.lowercased()
        let sourceURL = resolvedPaths.sourceURL
        let destURL = resolvedPaths.destinationURL
        let stagingSessionPath = destURL
            .appendingPathComponent("_ingest_staging", isDirectory: true)
            .appendingPathComponent(sessionID, isDirectory: true)
            .path
        let verificationEnabled = !skipVerify

        let receiptWriter = try ReceiptWriter(destRoot: destURL, sessionID: sessionID)
        let forcedMissingCaptureDatePaths = RollkeepCLI.parseRelativePathSetEnv(
            name: "ROLLKEEP_TEST_FORCE_MISSING_CAPTURE_DATE_RELATIVE_PATHS"
        )
        let preparationService = IngestPreparationService(
            sourceScanner: SourceScanner(
                forcedMissingCaptureDateRelativePaths: forcedMissingCaptureDatePaths
            ),
            destinationPathPlanner: DestinationPathPlanner(pathScheme: pathScheme)
        )
        let isoFormatter = ISO8601DateFormatter()

        var finalStatus = "completed"
        var failurePhase = IngestPhase.finalize
        var failureReason: String?
        var scanSummary: ScanSummary?
        var destinationPlan: DestinationPathPlanner.Plan?
        var cardAssessment: CameraCardAssessment?
        var touchedPaths = ReceiptTouchedPaths()
        var outcomeTotals = ReceiptOutcomeTotals()
        var pdfSummaryPath: String?
        var commitStageCompleted = false
        var phaseTimings = PhaseTimingTracker()
        var firstErrors: [String] = []
        var scanPhaseStartedAt: Date?
        var planPhaseStartedAt: Date?
        var copyPhaseStartedAt: Date?
        var commitPhaseStartedAt: Date?

        touchedPaths.addWrittenReceiptFile(receiptWriter.sink.path)

        func rememberError(_ message: String) {
            guard firstErrors.count < 3 else {
                return
            }
            firstErrors.append(message)
        }

        logger.info("command_started", metadata: [
            "session_id": sessionID,
            "source": sourceURL.path,
            "dest": destURL.path,
            "source_resolution": resolvedPaths.sourceResolution,
            "destination_resolution": resolvedPaths.destinationResolution,
            "dry_run": dryRun.description,
            "pdf": pdf.description,
            "json": json.description,
            "verify_after_copy": verificationEnabled.description,
            "max_parallel_copies": String(maxParallelCopies),
            "detect_timeout_seconds": String(detectTimeoutSeconds),
            "pick_source": pickSource.description,
            "pick_dest": pickDest.description,
            "config": config ?? "",
            "path_scheme": pathSchemeString,
            "receipt_path": receiptWriter.sink.path,
            "receipt_sink": receiptWriter.sink.kind.rawValue,
        ])

        try receiptWriter.append(eventType: .sessionStarted, phase: .scan, data: [
            "source": sourceURL.path,
            "destination": destURL.path,
            "dry_run": dryRun,
            "pdf_summary_requested": pdf,
            "json_summary_requested": json,
            "verify_after_copy": verificationEnabled,
            "max_parallel_copies": maxParallelCopies,
            "source_resolution": resolvedPaths.sourceResolution,
            "destination_resolution": resolvedPaths.destinationResolution,
            "detect_timeout_seconds": detectTimeoutSeconds,
            "pick_source": pickSource,
            "pick_dest": pickDest,
            "path_scheme": pathSchemeString,
            "receipt_path": receiptWriter.sink.path,
            "receipt_sink": receiptWriter.sink.kind.rawValue,
        ])

        if let config {
            logger.warn("config_not_implemented", metadata: ["path": config])
        }

        do {
            scanPhaseStartedAt = Date()
            let scanProgressWriteError = ThreadSafeErrorBox()

            let preparation = try preparationService.prepare(
                sourceRoot: sourceURL,
                destRoot: destURL,
                sessionID: sessionID,
                progress: { snapshot in
                    var data: [String: Any] = [
                        "files_checked": snapshot.filesChecked,
                        "bytes_checked": snapshot.bytesChecked,
                        "candidate_count": snapshot.itemCount,
                        "photos": [
                            "count": snapshot.photoCount,
                            "bytes": snapshot.photoBytes,
                        ],
                        "videos": [
                            "count": snapshot.videoCount,
                            "bytes": snapshot.videoBytes,
                        ],
                    ]
                    if let currentRelativePath = snapshot.currentRelativePath, !currentRelativePath.isEmpty {
                        data["path"] = currentRelativePath
                    }

                    do {
                        try receiptWriter.append(eventType: .scanProgress, phase: .scan, data: data)
                    } catch {
                        scanProgressWriteError.recordIfNeeded(error)
                    }
                }
            )
            if let writeError = scanProgressWriteError.value {
                throw writeError
            }
            let summary = preparation.scanSummary
            scanSummary = summary

            for errorRecord in summary.errors {
                outcomeTotals.errors += 1
                rememberError("[scan] \(errorRecord.path): \(errorRecord.message)")
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
                "warning_count": summary.warnings.count,
            ])
            if let startedAt = scanPhaseStartedAt {
                phaseTimings.capture(.scan, startedAt: startedAt)
                scanPhaseStartedAt = nil
            }

            planPhaseStartedAt = Date()
            let cameraInferenceByPath = preparation.cameraInferenceByPath
            guard let plan = preparation.plan else {
                throw IngestRuntimeError(phase: .plan, message: "Shared ingest preparation did not produce a destination plan")
            }
            destinationPlan = plan

            let assessment = preparation.cameraAssessment
            cardAssessment = assessment

            let cameraDistribution = assessment.distribution.map { entry in
                [
                    "camera_label": entry.cameraLabel,
                    "file_count": entry.fileCount,
                ] as [String: Any]
            }

            let cameraDetectedData: [String: Any] = [
                "camera_label": assessment.cameraLabel,
                "mixed_camera_detected": assessment.mixedCameraDetected,
                "total_candidates": assessment.totalCandidates,
                "known_camera_file_count": assessment.knownCameraFileCount,
                "unknown_camera_file_count": assessment.unknownCameraFileCount,
                "labels": cameraDistribution,
            ]
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
                "path_scheme": pathSchemeString,
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
            var sourceDatesByPath: [String: (modificationDate: Date, creationDate: Date?)] = [:]

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
                    sourceDatesByPath[planned.candidate.absolutePath] = (
                        modificationDate: planned.candidate.mtime,
                        creationDate: planned.candidate.creationDate
                    )

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

                    if dryRun {
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
            }
            if let startedAt = planPhaseStartedAt {
                phaseTimings.capture(.plan, startedAt: startedAt)
                planPhaseStartedAt = nil
            }

            let plannedBySourcePath = Dictionary(uniqueKeysWithValues: plan.files.map { planned in
                (planned.candidate.absolutePath, planned)
            })

            let orderedFiles = buildScanFileListEntries(
                summary: summary,
                plan: plan,
                cameraInferenceByPath: cameraInferenceByPath,
                preparation: preparation,
                isoFormatter: isoFormatter
            )

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

            for warning in summary.warnings {
                logger.warn("unknown_large_file_extension_skipped", metadata: [
                    "session_id": sessionID,
                    "path": warning.path,
                    "extension": warning.fileExtension,
                    "size_bytes": String(warning.sizeBytes),
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
                "warning_count": String(summary.warnings.count),
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
                var copyPhaseDurationMS = 0
                var verifyPhaseDurationMS = 0
                copyPhaseStartedAt = Date()
                let injectVerifyCorruption = ProcessInfo.processInfo.environment["ROLLKEEP_TEST_CORRUPT_STAGING_BEFORE_VERIFY"] == "1"
                let failCopyOnNthFile = RollkeepCLI.parsePositiveIntEnv(name: "ROLLKEEP_TEST_FAIL_COPY_ON_NTH_FILE")
                let failCopyMessage = ProcessInfo.processInfo.environment["ROLLKEEP_TEST_FAIL_COPY_ERROR_MESSAGE"] ?? "Simulated copy failure"
                let failCommitOnNthFile = RollkeepCLI.parsePositiveIntEnv(name: "ROLLKEEP_TEST_FAIL_COMMIT_ON_NTH_FILE")
                let failCommitMessage = ProcessInfo.processInfo.environment["ROLLKEEP_TEST_FAIL_COMMIT_ERROR_MESSAGE"] ?? "Simulated commit failure"
                let sleepBeforeCommitSeconds = RollkeepCLI.parsePositiveIntEnv(name: "ROLLKEEP_TEST_SLEEP_BEFORE_COMMIT_SECONDS")
                let copyStartEventLock = NSLock()
                var copyStartEventError: Error?
                let verifyInjectionLock = NSLock()
                var verifyInjectionTriggered = false
                var verifyInjectionError: Error?
                let copyFaultInjectionLock = NSLock()
                var copyFaultInjectionCount = 0

                func readCopyStartEventError() -> Error? {
                    copyStartEventLock.lock()
                    defer { copyStartEventLock.unlock() }
                    return copyStartEventError
                }

                func readVerifyInjectionState() -> (triggered: Bool, error: Error?) {
                    verifyInjectionLock.lock()
                    defer { verifyInjectionLock.unlock() }
                    return (verifyInjectionTriggered, verifyInjectionError)
                }

                let copyEngine = StagingCopyEngine(
                    configuration: .init(
                        verifyAfterCopy: verificationEnabled,
                        maxParallelCopies: maxParallelCopies
                    ),
                    onEvent: { event in
                        guard case let .started(job) = event else {
                            return
                        }

                        copyStartEventLock.lock()
                        defer { copyStartEventLock.unlock() }

                        guard copyStartEventError == nil else {
                            return
                        }

                        do {
                            try receiptWriter.append(eventType: .fileCopyStarted, phase: .copy, data: [
                                "path": job.relativePath,
                                "source_path": job.sourcePath,
                                "staging_path": job.stagingPath,
                                "final_path": job.finalPath,
                                "expected_bytes": job.expectedBytes,
                                "verification_enabled": verificationEnabled,
                                "status": "started",
                                "executed": true,
                            ])
                        } catch {
                            copyStartEventError = error
                        }
                    },
                    onBeforeCopy: { _ in
                        guard let failCopyOnNthFile else {
                            return
                        }

                        copyFaultInjectionLock.lock()
                        defer { copyFaultInjectionLock.unlock() }
                        copyFaultInjectionCount += 1
                        if copyFaultInjectionCount == failCopyOnNthFile {
                            throw TestFaultInjectionError(message: failCopyMessage)
                        }
                    },
                    onPreVerify: { job in
                        guard injectVerifyCorruption else {
                            return
                        }

                        verifyInjectionLock.lock()
                        defer { verifyInjectionLock.unlock() }

                        guard !verifyInjectionTriggered else {
                            return
                        }

                        do {
                            try RollkeepCLI.corruptStagedFileForVerifyMismatch(path: job.stagingPath)
                        } catch {
                            verifyInjectionError = error
                        }

                        verifyInjectionTriggered = true
                    }
                )

                let copyResults: [StagingCopyEngine.FileResult]
                do {
                    copyResults = try copyEngine.copyToStaging(files: copyJobs)
                    if let appendError = readCopyStartEventError() {
                        throw IngestRuntimeError(
                            phase: .copy,
                            message: "Failed to append FILE_COPY_STARTED event: \(appendError.localizedDescription)"
                        )
                    }
                    if injectVerifyCorruption {
                        let injectionState = readVerifyInjectionState()
                        if let error = injectionState.error {
                            throw IngestRuntimeError(
                                phase: .verify,
                                message: "Failed to inject verify corruption: \(error.localizedDescription)"
                            )
                        }
                        if !injectionState.triggered {
                            throw IngestRuntimeError(
                                phase: .verify,
                                message: "Verify corruption injection requested but was not triggered"
                            )
                        }
                    }
                } catch let engineError as StagingCopyEngine.EngineError {
                    switch engineError {
                    case .invalidConfiguration(let message):
                        throw IngestRuntimeError(phase: .copy, message: message)
                    case .runFailed(let partialResults, let failure):
                        copyPhaseDurationMS += partialResults.reduce(0) { $0 + $1.copyDurationMS }
                        copyPhaseDurationMS += failure.copyDurationMS
                        verifyPhaseDurationMS += partialResults.reduce(0) { $0 + $1.verifyDurationMS }
                        verifyPhaseDurationMS += failure.verifyDurationMS
                        phaseTimings.add(.copy, milliseconds: copyPhaseDurationMS)
                        phaseTimings.add(.verify, milliseconds: verifyPhaseDurationMS)

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
                copyPhaseDurationMS += copyResults.reduce(0) { $0 + $1.copyDurationMS }
                verifyPhaseDurationMS += copyResults.reduce(0) { $0 + $1.verifyDurationMS }
                phaseTimings.add(.copy, milliseconds: copyPhaseDurationMS)
                phaseTimings.add(.verify, milliseconds: verifyPhaseDurationMS)
                copyPhaseStartedAt = nil

                logger.info("copy_stage_completed", metadata: [
                    "session_id": sessionID,
                    "copied_count": String(outcomeTotals.copied),
                    "verified_count": String(outcomeTotals.verified),
                    "verification_skipped_count": String(outcomeTotals.verificationSkipped),
                ])

                var commitJobs: [StagingCommitEngine.FileJob] = []
                commitJobs.reserveCapacity(copyResults.count)
                for result in copyResults {
                    guard let sourceDates = sourceDatesByPath[result.sourcePath] else {
                        throw IngestRuntimeError(
                            phase: .plan,
                            message: "Missing source date metadata for \(result.sourcePath)"
                        )
                    }

                    commitJobs.append(StagingCommitEngine.FileJob(
                        relativePath: result.relativePath,
                        sourcePath: result.sourcePath,
                        stagingPath: result.stagingPath,
                        plannedFinalPath: result.finalPath,
                        plannedCollisionSuffix: plannedBySourcePath[result.sourcePath]?.collisionSuffix,
                        bytesCopied: result.bytesCopied,
                        sourceHashSHA256: result.sourceHashSHA256,
                        sourceModificationDate: sourceDates.modificationDate,
                        sourceCreationDate: sourceDates.creationDate
                    ))
                }

                if let sleepBeforeCommitSeconds, sleepBeforeCommitSeconds > 0 {
                    logger.info("test_pause_before_commit", metadata: [
                        "session_id": sessionID,
                        "seconds": String(sleepBeforeCommitSeconds),
                    ])
                    Thread.sleep(forTimeInterval: TimeInterval(sleepBeforeCommitSeconds))
                }

                commitPhaseStartedAt = Date()
                for job in commitJobs {
                    try receiptWriter.append(eventType: .fileCommitStarted, phase: .commit, data: [
                        "path": job.relativePath,
                        "source_path": job.sourcePath,
                        "staging_path": job.stagingPath,
                        "final_path": job.plannedFinalPath,
                        "planned_final_path": job.plannedFinalPath,
                        "status": "queued",
                        "executed": true,
                    ])
                }

                var commitFaultInjectionCount = 0
                let commitEngine = StagingCommitEngine(onBeforeMove: { _, _ in
                    guard let failCommitOnNthFile else {
                        return
                    }
                    commitFaultInjectionCount += 1
                    if commitFaultInjectionCount == failCommitOnNthFile {
                        throw TestFaultInjectionError(message: failCommitMessage)
                    }
                })
                let commitResults: [StagingCommitEngine.FileResult]
                do {
                    commitResults = try commitEngine.commit(files: commitJobs)
                } catch let engineError as StagingCommitEngine.EngineError {
                    switch engineError {
                    case .invalidConfiguration(let message):
                        throw IngestRuntimeError(phase: .commit, message: message)
                    case .runFailed(let partialResults, let remaining, let failure):
                        if let startedAt = commitPhaseStartedAt {
                            phaseTimings.capture(.commit, startedAt: startedAt)
                            commitPhaseStartedAt = nil
                        }
                        try appendCommitResults(
                            partialResults,
                            receiptWriter: receiptWriter,
                            touchedPaths: &touchedPaths,
                            outcomeTotals: &outcomeTotals
                        )
                        try appendCommitFailure(
                            failure,
                            remainingJobs: remaining,
                            committedResults: partialResults,
                            receiptWriter: receiptWriter
                        )

                        let message = "Failed during commit for \(failure.relativePath): \(failure.message)"
                        throw IngestRuntimeError(
                            phase: .commit,
                            message: message,
                            receiptErrorRecorded: true
                        )
                    }
                }

                try appendCommitResults(
                    commitResults,
                    receiptWriter: receiptWriter,
                    touchedPaths: &touchedPaths,
                    outcomeTotals: &outcomeTotals
                )
                if let startedAt = commitPhaseStartedAt {
                    phaseTimings.capture(.commit, startedAt: startedAt)
                    commitPhaseStartedAt = nil
                }
                commitStageCompleted = true

                logger.info("commit_stage_completed", metadata: [
                    "session_id": sessionID,
                    "committed_count": String(outcomeTotals.committed),
                    "duplicate_not_copied_count": String(outcomeTotals.duplicateNotCopied),
                    "conflicts_renamed_count": String(outcomeTotals.conflictsRenamed),
                ])
            }

        } catch {
            finalStatus = "aborted"
            let context = failureContext(from: error)
            failurePhase = context.phase
            failureReason = context.message
            outcomeTotals.errors += 1
            rememberError("[\(context.phase.rawValue)] \(context.message)")

            switch context.phase {
            case .scan:
                if let startedAt = scanPhaseStartedAt, phaseTimings.value(for: .scan) == 0 {
                    phaseTimings.capture(.scan, startedAt: startedAt)
                }
            case .plan:
                if let startedAt = planPhaseStartedAt, phaseTimings.value(for: .plan) == 0 {
                    phaseTimings.capture(.plan, startedAt: startedAt)
                }
            case .copy:
                if let startedAt = copyPhaseStartedAt, phaseTimings.value(for: .copy) == 0 {
                    phaseTimings.capture(.copy, startedAt: startedAt)
                }
            case .verify:
                if let startedAt = copyPhaseStartedAt, phaseTimings.value(for: .verify) == 0 {
                    phaseTimings.capture(.verify, startedAt: startedAt)
                }
            case .commit:
                if let startedAt = commitPhaseStartedAt, phaseTimings.value(for: .commit) == 0 {
                    phaseTimings.capture(.commit, startedAt: startedAt)
                }
            case .finalize:
                break
            }
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

        if finalStatus == "completed", !dryRun {
            do {
                if try StagingSessionCleanup().removeIfPresent(path: stagingSessionPath) {
                    touchedPaths.addDeletedPath(stagingSessionPath)
                    logger.info("staging_session_removed", metadata: [
                        "session_id": sessionID,
                        "path": stagingSessionPath,
                    ])
                }
            } catch {
                outcomeTotals.errors += 1
                let message = "Failed to remove staging session directory: \(error.localizedDescription)"
                rememberError("[finalize] \(message)")
                logger.warn("staging_session_remove_failed", metadata: [
                    "session_id": sessionID,
                    "path": stagingSessionPath,
                    "error": error.localizedDescription,
                ])
                do {
                    try receiptWriter.append(eventType: .error, phase: .finalize, data: [
                        "error": message,
                        "staging_path": stagingSessionPath,
                    ])
                } catch {
                    logger.error("receipt_append_failed_after_cleanup_error", metadata: [
                        "session_id": sessionID,
                        "error": error.localizedDescription,
                    ])
                }
            }
        }

        let finalizePhaseStartedAt = Date()

        var summaryData = buildSummaryData(
            finalStatus: finalStatus,
            dryRun: dryRun,
            verificationEnabled: verificationEnabled,
            commitStageCompleted: commitStageCompleted,
            scanSummary: scanSummary,
            destinationPlan: destinationPlan,
            cardAssessment: cardAssessment,
            outcomeTotals: outcomeTotals,
            touchedPaths: touchedPaths,
            receiptWriter: receiptWriter,
            pdfSummaryPath: pdfSummaryPath,
            phaseTimings: phaseTimings,
            isoFormatter: isoFormatter,
            pathSchemeString: pathSchemeString
        )

        if pdf {
            do {
                let effectiveScanSummary = scanSummary ?? ScanSummary(
                    candidates: [],
                    photoCount: 0,
                    videoCount: 0,
                    photoBytes: 0,
                    videoBytes: 0,
                    filesInTypicalLocations: 0,
                    filesOutsideTypicalLocations: 0,
                    errors: []
                )

                let pdfURL = try PDFReceiptExporter().write(
                    sessionID: sessionID,
                    sourcePath: sourceURL.path,
                    destinationPath: destURL.path,
                    dryRun: dryRun,
                    receiptSink: receiptWriter.sink,
                    generatedAt: Date(),
                    finalStatus: finalStatus,
                    verificationEnabled: verificationEnabled,
                    failurePhase: finalStatus == "aborted" ? failurePhase : nil,
                    failureReason: failureReason,
                    summary: summaryData,
                    scanSummary: effectiveScanSummary
                )

                pdfSummaryPath = pdfURL.path
                touchedPaths.addWrittenReceiptFile(pdfURL.path)

                logger.info("receipt_pdf_written", metadata: [
                    "session_id": sessionID,
                    "path": pdfURL.path,
                ])

                try receiptWriter.append(eventType: .receiptPDFWritten, phase: .finalize, data: [
                    "path": pdfURL.path,
                ])
            } catch {
                outcomeTotals.errors += 1
                let message = "PDF receipt write failed: \(error.localizedDescription)"
                rememberError("[finalize] \(message)")
                logger.warn("receipt_pdf_write_failed", metadata: [
                    "session_id": sessionID,
                    "error": message,
                ])
                do {
                    try receiptWriter.append(eventType: .error, phase: .finalize, data: [
                        "error": message,
                    ])
                } catch {
                    logger.error("receipt_append_failed_after_pdf_error", metadata: [
                        "session_id": sessionID,
                        "error": error.localizedDescription,
                    ])
                }
            }

            summaryData = buildSummaryData(
                finalStatus: finalStatus,
                dryRun: dryRun,
                verificationEnabled: verificationEnabled,
                commitStageCompleted: commitStageCompleted,
                scanSummary: scanSummary,
                destinationPlan: destinationPlan,
                cardAssessment: cardAssessment,
                outcomeTotals: outcomeTotals,
                touchedPaths: touchedPaths,
                receiptWriter: receiptWriter,
                pdfSummaryPath: pdfSummaryPath,
                phaseTimings: phaseTimings,
                isoFormatter: isoFormatter,
                pathSchemeString: pathSchemeString
            )
        }

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
            "path_scheme": pathSchemeString,
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
        phaseTimings.capture(.finalize, startedAt: finalizePhaseStartedAt)

        let resolvedFailurePhase: IngestPhase? = finalStatus == "aborted" ? failurePhase : nil
        let resolvedExitCode = RollkeepExitCode.resolve(finalStatus: finalStatus, failurePhase: resolvedFailurePhase)
        let finalSummaryPayload = FinalSummaryPayload(
            sessionID: sessionID,
            finalStatus: finalStatus,
            exitCode: resolvedExitCode.rawValue,
            dryRun: dryRun,
            verificationEnabled: verificationEnabled,
            receiptPath: receiptWriter.sink.path,
            receiptSink: receiptWriter.sink.kind,
            stagingSessionPath: stagingSessionPath,
            pdfSummaryPath: pdfSummaryPath,
            failurePhase: resolvedFailurePhase,
            failureReason: failureReason,
            firstErrors: firstErrors,
            phaseTimings: phaseTimings.allPhases(),
            counts: FinalSummaryCounts(
                candidates: scanSummary?.candidates.count ?? 0,
                photos: scanSummary?.photoCount ?? 0,
                videos: scanSummary?.videoCount ?? 0,
                copied: outcomeTotals.copied,
                verified: outcomeTotals.verified,
                committed: outcomeTotals.committed,
                duplicateNotCopied: outcomeTotals.duplicateNotCopied,
                conflictsRenamed: outcomeTotals.conflictsRenamed,
                errors: outcomeTotals.errors
            )
        )

        let finalSummaryRenderer = FinalSummaryRenderer()
        if json {
            print(finalSummaryRenderer.renderJSON(finalSummaryPayload))
        } else {
            print(finalSummaryRenderer.renderHuman(finalSummaryPayload))
        }

        if resolvedExitCode != .success {
            throw ExitCode(resolvedExitCode.rawValue)
        }
    }

    private static func corruptStagedFileForVerifyMismatch(path: String) throws {
        let fileURL = URL(fileURLWithPath: path, isDirectory: false)
        let handle = try FileHandle(forUpdating: fileURL)
        defer { try? handle.close() }

        try handle.seek(toOffset: 0)
        let originalFirstByte = try handle.read(upToCount: 1) ?? Data([0x00])
        let baseline = originalFirstByte.first ?? 0x00
        let replacement = Data([baseline ^ 0xFF])

        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: replacement)
        try handle.synchronize()
    }

    private static func parsePositiveIntEnv(name: String) -> Int? {
        guard let rawValue = ProcessInfo.processInfo.environment[name] else {
            return nil
        }
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Int(trimmed), value > 0 else {
            return nil
        }
        return value
    }

    private static func parseRelativePathSetEnv(name: String) -> Set<String> {
        guard let rawValue = ProcessInfo.processInfo.environment[name] else {
            return []
        }

        return Set(rawValue
            .split(separator: ",")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        )
    }

    private func resolvePathScheme() throws -> ImportPathScheme {
        let chronologicalLayout: PathChronologicalLayout
        if let pathChronological {
            guard let parsed = PathChronologicalLayout.parseCLIValue(pathChronological) else {
                throw ValidationError("--path-chronological must be one of: YYYY/YYYYMM, YYYY/MM")
            }
            chronologicalLayout = parsed
        } else {
            chronologicalLayout = .yearYearMonthCompact
        }

        return ImportPathScheme(
            chronologicalLayout: chronologicalLayout,
            includeCameraFolder: !pathNoCamera,
            splitPhotoCompression: pathSplitRaw
        )
    }


    private func failureContext(from error: Error) -> FailureContext {
        if let sourceError = error as? SourceScannerError {
            switch sourceError {
            case .unreadableSourceRoot(let path):
                return FailureContext(
                    phase: .scan,
                    message: "Source root unreadable: \(path)"
                )
            case .symbolicLinkDetected(let path):
                return FailureContext(
                    phase: .scan,
                    message: "Source scan blocked symlink entry: \(path)"
                )
            case .sourceBoundaryViolation(let path, let sourceRoot):
                return FailureContext(
                    phase: .scan,
                    message: "Source scan boundary violation: \(path) escapes \(sourceRoot)"
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
}
