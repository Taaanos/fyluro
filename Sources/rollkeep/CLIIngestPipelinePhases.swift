import Foundation
import RollKeepCore

extension RollkeepCLI {
    func logCommandStartedAndWriteSessionStart(
        context: CLIIngestSessionContext,
        logger: StructuredLogger,
        receiptWriter: ReceiptWriter
    ) throws {
        logger.info("command_started", metadata: [
            "session_id": context.sessionID,
            "source": context.sourceURL.path,
            "dest": context.destinationURL.path,
            "source_resolution": context.sourceResolution,
            "destination_resolution": context.destinationResolution,
            "dry_run": context.dryRun.description,
            "pdf": context.pdf.description,
            "json": context.json.description,
            "max_parallel_copies": String(context.maxParallelCopies),
            "detect_timeout_seconds": String(context.detectTimeoutSeconds),
            "pick_source": context.pickSource.description,
            "pick_dest": context.pickDestination.description,
            "path_scheme": context.pathSchemeString,
            "receipt_path": receiptWriter.sink.path,
            "receipt_sink": receiptWriter.sink.kind.rawValue,
        ])

        try receiptWriter.append(eventType: .sessionStarted, phase: .scan, data: [
            "source": context.sourceURL.path,
            "destination": context.destinationURL.path,
            "dry_run": context.dryRun,
            "pdf_summary_requested": context.pdf,
            "json_summary_requested": context.json,
            "max_parallel_copies": context.maxParallelCopies,
            "source_resolution": context.sourceResolution,
            "destination_resolution": context.destinationResolution,
            "detect_timeout_seconds": context.detectTimeoutSeconds,
            "pick_source": context.pickSource,
            "pick_dest": context.pickDestination,
            "path_scheme": context.pathSchemeString,
            "receipt_path": receiptWriter.sink.path,
            "receipt_sink": receiptWriter.sink.kind.rawValue,
        ])
    }

    func executePipelinePhases(
        context: CLIIngestSessionContext,
        state: inout CLIIngestSessionState,
        preparationService: IngestPreparationService,
        isoFormatter: ISO8601DateFormatter,
        logger: StructuredLogger,
        receiptWriter: ReceiptWriter
    ) throws {
        let scanPlan = try runScanAndPlanPhase(
            context: context,
            state: &state,
            preparationService: preparationService,
            isoFormatter: isoFormatter,
            logger: logger,
            receiptWriter: receiptWriter
        )

        try runCopyVerifyCommitPhase(
            context: context,
            state: &state,
            scanPlan: scanPlan,
            logger: logger,
            receiptWriter: receiptWriter
        )
    }

    func runScanAndPlanPhase(
        context: CLIIngestSessionContext,
        state: inout CLIIngestSessionState,
        preparationService: IngestPreparationService,
        isoFormatter: ISO8601DateFormatter,
        logger: StructuredLogger,
        receiptWriter: ReceiptWriter
    ) throws -> CLIIngestScanPlanOutput {
        state.scanPhaseStartedAt = Date()
        let scanProgressWriteError = ThreadSafeErrorBox()

        let preparation = try preparationService.prepare(
            sourceRoot: context.sourceURL,
            destRoot: context.destinationURL,
            sessionID: context.sessionID,
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
        state.scanSummary = summary

        for errorRecord in summary.errors {
            state.outcomeTotals.errors += 1
            state.rememberError("[scan] \(errorRecord.path): \(errorRecord.message)")
            logger.error("scan_file_error", metadata: [
                "session_id": context.sessionID,
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
        if let startedAt = state.scanPhaseStartedAt {
            state.phaseTimings.capture(.scan, startedAt: startedAt)
            state.scanPhaseStartedAt = nil
        }

        state.planPhaseStartedAt = Date()
        let cameraInferenceByPath = preparation.cameraInferenceByPath
        guard let plan = preparation.plan else {
            throw IngestRuntimeError(phase: .plan, message: "Shared ingest preparation did not produce a destination plan")
        }
        state.destinationPlan = plan

        let assessment = preparation.cameraAssessment
        state.cardAssessment = assessment

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
            "path_scheme": context.pathSchemeString,
            "files": plannedFilesForReceipt,
        ])

        for directoryPath in plan.directoriesToCreate {
            state.touchedPaths.addCreatedDirectory(directoryPath)
            try receiptWriter.append(eventType: .dirCreated, phase: .plan, data: [
                "path": directoryPath,
                "status": "planned",
            ])
        }

        var copyJobs: [StagingCopyEngine.FileJob] = []
        var sourceDatesByPath: [String: (modificationDate: Date, creationDate: Date?)] = [:]

        for planned in plan.files {
            if planned.collisionResolved {
                state.outcomeTotals.conflictsRenamed += 1
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
                state.outcomeTotals.duplicateNotCopied += 1
                state.touchedPaths.addPlannedFinalFile(planned.finalPath)

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
                state.outcomeTotals.plannedStageAndCommit += 1
                guard let stagingPath = planned.stagingPath else {
                    continue
                }

                state.touchedPaths.addPlannedStagingFile(stagingPath)
                state.touchedPaths.addPlannedFinalFile(planned.finalPath)
                state.touchedPaths.addPlannedMove(from: stagingPath, to: planned.finalPath)

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

                if context.dryRun {
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

        if let startedAt = state.planPhaseStartedAt {
            state.phaseTimings.capture(.plan, startedAt: startedAt)
            state.planPhaseStartedAt = nil
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
                "session_id": context.sessionID,
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
            let logEvent: String
            switch warning.category {
            case .unknownLargeSkippedFile:
                logEvent = "unknown_large_file_extension_skipped"
            case .symbolicLinkSkipped:
                logEvent = "symbolic_link_skipped"
            }
            logger.warn(logEvent, metadata: [
                "session_id": context.sessionID,
                "path": warning.path,
                "category": warning.category.rawValue,
                "extension": warning.fileExtension,
                "size_bytes": String(warning.sizeBytes),
            ])

            try receiptWriter.append(eventType: .scanWarning, phase: .scan, data: [
                "path": warning.path,
                "category": warning.category.rawValue,
                "message": warning.message,
                "extension": warning.fileExtension,
                "size_bytes": warning.sizeBytes,
            ])
        }

        try receiptWriter.append(eventType: .scanFileList, phase: .scan, data: [
            "files": orderedFiles,
        ])

        logger.info("scan_summary", metadata: [
            "session_id": context.sessionID,
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
            "session_id": context.sessionID,
            "planned_file_count": String(plan.files.count),
            "directories_to_create_count": String(plan.directoriesToCreate.count),
            "duplicate_not_copied_count": String(plan.duplicatesSkipped),
            "conflicts_renamed_count": String(plan.conflictsRenamed),
        ])

        if context.dryRun {
            logger.info("dry_run_complete", metadata: ["note": "scan+plan completed; no files copied"])
        }

        return CLIIngestScanPlanOutput(
            preparation: preparation,
            summary: summary,
            plan: plan,
            copyJobs: copyJobs,
            sourceDatesByPath: sourceDatesByPath,
            plannedBySourcePath: plannedBySourcePath
        )
    }

    func runCopyVerifyCommitPhase(
        context: CLIIngestSessionContext,
        state: inout CLIIngestSessionState,
        scanPlan: CLIIngestScanPlanOutput,
        logger: StructuredLogger,
        receiptWriter: ReceiptWriter
    ) throws {
        guard !context.dryRun else {
            return
        }

        var copyPhaseDurationMS = 0
        var verifyPhaseDurationMS = 0
        state.copyPhaseStartedAt = Date()

        let injectVerifyCorruption = ProcessInfo.processInfo.environment["ROLLKEEP_TEST_CORRUPT_STAGING_BEFORE_VERIFY"] == "1"
        let failCopyOnNthFile = CLIIngestEnvironmentParsing.parsePositiveInt(name: "ROLLKEEP_TEST_FAIL_COPY_ON_NTH_FILE")
        let failCopyMessage = ProcessInfo.processInfo.environment["ROLLKEEP_TEST_FAIL_COPY_ERROR_MESSAGE"] ?? "Simulated copy failure"
        let failCommitOnNthFile = CLIIngestEnvironmentParsing.parsePositiveInt(name: "ROLLKEEP_TEST_FAIL_COMMIT_ON_NTH_FILE")
        let failCommitMessage = ProcessInfo.processInfo.environment["ROLLKEEP_TEST_FAIL_COMMIT_ERROR_MESSAGE"] ?? "Simulated commit failure"
        let sleepBeforeCommitSeconds = CLIIngestEnvironmentParsing.parsePositiveInt(name: "ROLLKEEP_TEST_SLEEP_BEFORE_COMMIT_SECONDS")

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
                verifyAfterCopy: true,
                maxParallelCopies: context.maxParallelCopies
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
            copyResults = try copyEngine.copyToStaging(files: scanPlan.copyJobs)
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
                state.phaseTimings.add(.copy, milliseconds: copyPhaseDurationMS)
                state.phaseTimings.add(.verify, milliseconds: verifyPhaseDurationMS)

                try appendCopyResults(
                    partialResults,
                    receiptWriter: receiptWriter,
                    touchedPaths: &state.touchedPaths,
                    outcomeTotals: &state.outcomeTotals
                )
                try appendCopyFailure(
                    failure,
                    receiptWriter: receiptWriter,
                    touchedPaths: &state.touchedPaths,
                    outcomeTotals: &state.outcomeTotals
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
            receiptWriter: receiptWriter,
            touchedPaths: &state.touchedPaths,
            outcomeTotals: &state.outcomeTotals
        )
        copyPhaseDurationMS += copyResults.reduce(0) { $0 + $1.copyDurationMS }
        verifyPhaseDurationMS += copyResults.reduce(0) { $0 + $1.verifyDurationMS }
        state.phaseTimings.add(.copy, milliseconds: copyPhaseDurationMS)
        state.phaseTimings.add(.verify, milliseconds: verifyPhaseDurationMS)
        state.copyPhaseStartedAt = nil

        logger.info("copy_stage_completed", metadata: [
            "session_id": context.sessionID,
            "copied_count": String(state.outcomeTotals.copied),
            "verified_count": String(state.outcomeTotals.verified),
        ])

        var commitJobs: [StagingCommitEngine.FileJob] = []
        commitJobs.reserveCapacity(copyResults.count)

        for result in copyResults {
            guard let sourceDates = scanPlan.sourceDatesByPath[result.sourcePath] else {
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
                plannedCollisionSuffix: scanPlan.plannedBySourcePath[result.sourcePath]?.collisionSuffix,
                bytesCopied: result.bytesCopied,
                sourceHashSHA256: result.sourceHashSHA256,
                sourceModificationDate: sourceDates.modificationDate,
                sourceCreationDate: sourceDates.creationDate
            ))
        }

        if let sleepBeforeCommitSeconds, sleepBeforeCommitSeconds > 0 {
            logger.info("test_pause_before_commit", metadata: [
                "session_id": context.sessionID,
                "seconds": String(sleepBeforeCommitSeconds),
            ])
            Thread.sleep(forTimeInterval: TimeInterval(sleepBeforeCommitSeconds))
        }

        state.commitPhaseStartedAt = Date()
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
                if let startedAt = state.commitPhaseStartedAt {
                    state.phaseTimings.capture(.commit, startedAt: startedAt)
                    state.commitPhaseStartedAt = nil
                }
                try appendCommitResults(
                    partialResults,
                    receiptWriter: receiptWriter,
                    touchedPaths: &state.touchedPaths,
                    outcomeTotals: &state.outcomeTotals
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
            touchedPaths: &state.touchedPaths,
            outcomeTotals: &state.outcomeTotals
        )
        if let startedAt = state.commitPhaseStartedAt {
            state.phaseTimings.capture(.commit, startedAt: startedAt)
            state.commitPhaseStartedAt = nil
        }
        state.commitStageCompleted = true

        logger.info("commit_stage_completed", metadata: [
            "session_id": context.sessionID,
            "committed_count": String(state.outcomeTotals.committed),
            "duplicate_not_copied_count": String(state.outcomeTotals.duplicateNotCopied),
            "conflicts_renamed_count": String(state.outcomeTotals.conflictsRenamed),
        ])
    }
}
