import Foundation
import RollKeepCore

extension RollkeepCLI {
    func handlePipelineFailure(
        context: CLIIngestSessionContext,
        state: inout CLIIngestSessionState,
        logger: StructuredLogger,
        receiptWriter: ReceiptWriter,
        error: Error
    ) {
        state.finalStatus = "aborted"
        let failureContext = CLIIngestFailureContextResolver.resolve(error)
        state.failurePhase = failureContext.phase
        state.failureReason = failureContext.message
        state.outcomeTotals.errors += 1
        state.rememberError("[\(failureContext.phase.rawValue)] \(failureContext.message)")

        switch failureContext.phase {
        case .scan:
            if let startedAt = state.scanPhaseStartedAt, state.phaseTimings.value(for: .scan) == 0 {
                state.phaseTimings.capture(.scan, startedAt: startedAt)
            }
        case .plan:
            if let startedAt = state.planPhaseStartedAt, state.phaseTimings.value(for: .plan) == 0 {
                state.phaseTimings.capture(.plan, startedAt: startedAt)
            }
        case .copy:
            if let startedAt = state.copyPhaseStartedAt, state.phaseTimings.value(for: .copy) == 0 {
                state.phaseTimings.capture(.copy, startedAt: startedAt)
            }
        case .verify:
            if let startedAt = state.copyPhaseStartedAt, state.phaseTimings.value(for: .verify) == 0 {
                state.phaseTimings.capture(.verify, startedAt: startedAt)
            }
        case .commit:
            if let startedAt = state.commitPhaseStartedAt, state.phaseTimings.value(for: .commit) == 0 {
                state.phaseTimings.capture(.commit, startedAt: startedAt)
            }
        case .finalize:
            break
        }

        let skipGenericReceiptError = (error as? IngestRuntimeError)?.receiptErrorRecorded ?? false

        logger.error("session_aborted", metadata: [
            "session_id": context.sessionID,
            "phase": failureContext.phase.rawValue,
            "error": failureContext.message,
        ])

        if !skipGenericReceiptError {
            do {
                try receiptWriter.append(eventType: .error, phase: failureContext.phase, data: [
                    "error": failureContext.message,
                ])
            } catch {
                logger.error("receipt_append_failed_after_abort", metadata: [
                    "session_id": context.sessionID,
                    "error": error.localizedDescription,
                ])
            }
        }
    }

    func finalizeSession(
        context: CLIIngestSessionContext,
        state: inout CLIIngestSessionState,
        isoFormatter: ISO8601DateFormatter,
        logger: StructuredLogger,
        receiptWriter: ReceiptWriter
    ) -> FinalSummaryPayload {
        if state.finalStatus == "completed", !context.dryRun {
            do {
                if try StagingSessionCleanup().removeIfPresent(path: context.stagingSessionPath) {
                    state.touchedPaths.addDeletedPath(context.stagingSessionPath)
                    logger.info("staging_session_removed", metadata: [
                        "session_id": context.sessionID,
                        "path": context.stagingSessionPath,
                    ])
                }
            } catch {
                state.outcomeTotals.errors += 1
                let message = "Failed to remove staging session directory: \(error.localizedDescription)"
                state.rememberError("[finalize] \(message)")
                logger.warn("staging_session_remove_failed", metadata: [
                    "session_id": context.sessionID,
                    "path": context.stagingSessionPath,
                    "error": error.localizedDescription,
                ])
                do {
                    try receiptWriter.append(eventType: .error, phase: .finalize, data: [
                        "error": message,
                        "staging_path": context.stagingSessionPath,
                    ])
                } catch {
                    logger.error("receipt_append_failed_after_cleanup_error", metadata: [
                        "session_id": context.sessionID,
                        "error": error.localizedDescription,
                    ])
                }
            }
        }

        let finalizePhaseStartedAt = Date()

        var summaryData = buildSummaryData(
            finalStatus: state.finalStatus,
            dryRun: context.dryRun,
            verificationEnabled: context.verificationEnabled,
            commitStageCompleted: state.commitStageCompleted,
            scanSummary: state.scanSummary,
            destinationPlan: state.destinationPlan,
            cardAssessment: state.cardAssessment,
            outcomeTotals: state.outcomeTotals,
            touchedPaths: state.touchedPaths,
            receiptWriter: receiptWriter,
            pdfSummaryPath: state.pdfSummaryPath,
            phaseTimings: state.phaseTimings,
            isoFormatter: isoFormatter,
            pathSchemeString: context.pathSchemeString
        )

        if context.pdf {
            do {
                let effectiveScanSummary = state.scanSummary ?? ScanSummary(
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
                    sessionID: context.sessionID,
                    sourcePath: context.sourceURL.path,
                    destinationPath: context.destinationURL.path,
                    dryRun: context.dryRun,
                    receiptSink: receiptWriter.sink,
                    generatedAt: Date(),
                    finalStatus: state.finalStatus,
                    verificationEnabled: context.verificationEnabled,
                    failurePhase: state.finalStatus == "aborted" ? state.failurePhase : nil,
                    failureReason: state.failureReason,
                    summary: summaryData,
                    scanSummary: effectiveScanSummary
                )

                state.pdfSummaryPath = pdfURL.path
                state.touchedPaths.addWrittenReceiptFile(pdfURL.path)

                logger.info("receipt_pdf_written", metadata: [
                    "session_id": context.sessionID,
                    "path": pdfURL.path,
                ])

                try receiptWriter.append(eventType: .receiptPDFWritten, phase: .finalize, data: [
                    "path": pdfURL.path,
                ])
            } catch {
                state.outcomeTotals.errors += 1
                let message = "PDF receipt write failed: \(error.localizedDescription)"
                state.rememberError("[finalize] \(message)")
                logger.warn("receipt_pdf_write_failed", metadata: [
                    "session_id": context.sessionID,
                    "error": message,
                ])
                do {
                    try receiptWriter.append(eventType: .error, phase: .finalize, data: [
                        "error": message,
                    ])
                } catch {
                    logger.error("receipt_append_failed_after_pdf_error", metadata: [
                        "session_id": context.sessionID,
                        "error": error.localizedDescription,
                    ])
                }
            }

            summaryData = buildSummaryData(
                finalStatus: state.finalStatus,
                dryRun: context.dryRun,
                verificationEnabled: context.verificationEnabled,
                commitStageCompleted: state.commitStageCompleted,
                scanSummary: state.scanSummary,
                destinationPlan: state.destinationPlan,
                cardAssessment: state.cardAssessment,
                outcomeTotals: state.outcomeTotals,
                touchedPaths: state.touchedPaths,
                receiptWriter: receiptWriter,
                pdfSummaryPath: state.pdfSummaryPath,
                phaseTimings: state.phaseTimings,
                isoFormatter: isoFormatter,
                pathSchemeString: context.pathSchemeString
            )
        }

        var summaryEventWritten = false
        do {
            try receiptWriter.append(eventType: .summary, phase: .finalize, data: summaryData)
            summaryEventWritten = true
        } catch {
            logger.error("receipt_summary_write_failed", metadata: [
                "session_id": context.sessionID,
                "error": error.localizedDescription,
            ])
        }

        var finishedData: [String: Any] = [
            "status": state.finalStatus,
            "dry_run": context.dryRun,
            "candidate_count": state.scanSummary?.candidates.count ?? 0,
            "error_count": state.outcomeTotals.errors,
            "receipt_path": receiptWriter.sink.path,
            "receipt_sink": receiptWriter.sink.kind.rawValue,
            "summary_event_written": summaryEventWritten,
            "path_scheme": context.pathSchemeString,
            "resume_hook": receiptWriter.resumeHook(),
        ]

        if let failureReason = state.failureReason {
            finishedData["failure_phase"] = state.failurePhase.rawValue
            finishedData["error"] = failureReason
        }

        do {
            try receiptWriter.append(eventType: .sessionFinished, phase: .finalize, data: finishedData)
        } catch {
            logger.error("receipt_session_finished_write_failed", metadata: [
                "session_id": context.sessionID,
                "error": error.localizedDescription,
            ])
        }
        state.phaseTimings.capture(.finalize, startedAt: finalizePhaseStartedAt)

        let resolvedFailurePhase: IngestPhase? = state.finalStatus == "aborted" ? state.failurePhase : nil
        let resolvedExitCode = RollkeepExitCode.resolve(finalStatus: state.finalStatus, failurePhase: resolvedFailurePhase)

        return FinalSummaryPayload(
            sessionID: context.sessionID,
            finalStatus: state.finalStatus,
            exitCode: resolvedExitCode.rawValue,
            dryRun: context.dryRun,
            verificationEnabled: context.verificationEnabled,
            receiptPath: receiptWriter.sink.path,
            receiptSink: receiptWriter.sink.kind,
            stagingSessionPath: context.stagingSessionPath,
            pdfSummaryPath: state.pdfSummaryPath,
            failurePhase: resolvedFailurePhase,
            failureReason: state.failureReason,
            firstErrors: state.firstErrors,
            phaseTimings: state.phaseTimings.allPhases(),
            counts: FinalSummaryCounts(
                candidates: state.scanSummary?.candidates.count ?? 0,
                photos: state.scanSummary?.photoCount ?? 0,
                videos: state.scanSummary?.videoCount ?? 0,
                copied: state.outcomeTotals.copied,
                verified: state.outcomeTotals.verified,
                committed: state.outcomeTotals.committed,
                duplicateNotCopied: state.outcomeTotals.duplicateNotCopied,
                conflictsRenamed: state.outcomeTotals.conflictsRenamed,
                errors: state.outcomeTotals.errors
            )
        )
    }
}
