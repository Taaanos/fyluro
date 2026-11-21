import Foundation
import FyluroCore

extension IngestSession {
    func handlePipelineFailure(
        context: IngestSessionContext,
        state: inout IngestSessionState,
        logger: any IngestLogging,
        receiptWriter: ReceiptWriter,
        error: Error
    ) {
        let failureContext = IngestFailureContextResolver.resolve(error)
        state.outcome = .aborted(phase: failureContext.phase, reason: failureContext.message)
        emit(.errorRecorded(phase: failureContext.phase, message: failureContext.message, paths: []))
        state.outcomeTotals.errors += 1
        state.rememberError("[\(failureContext.phase.rawValue)] \(failureContext.message)")

        state.phaseTimings.finishActiveOnFailure(for: failureContext.phase)

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
        context: IngestSessionContext,
        state: inout IngestSessionState,
        isoFormatter: ISO8601DateFormatter,
        logger: any IngestLogging,
        receiptWriter: ReceiptWriter
    ) -> IngestSessionResult {
        emit(.phaseChanged(.finalize))
        if state.outcome.isCompleted, !context.dryRun {
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
            finalStatus: state.outcome.statusString,
            dryRun: context.dryRun,
            commitStageCompleted: state.commitStageCompleted,
            scanSummary: state.scanSummary,
            destinationPlan: state.destinationPlan,
            cardAssessment: state.cardAssessment,
            outcomeTotals: state.outcomeTotals,
            touchedPaths: state.touchedPaths,
            commitResultsBySourcePath: state.commitResultsBySourcePath,
            receiptWriter: receiptWriter,
            pdfSummaryPath: state.pdfSummaryPath,
            phaseTimings: state.phaseTimings,
            isoFormatter: isoFormatter,
            pathSchemeString: context.pathSchemeString,
            filmModeOverride: context.filmModeOverride,
            filmModeExifApplied: state.filmModeExifApplied,
            filmModeExifSkipped: state.filmModeExifSkipped
        )

        if context.pdf {
            do {
                let effectiveScanSummary = state.scanSummary ?? ScanSummary(
                    candidates: [],
                    photoCount: 0,
                    videoCount: 0,
                    audioCount: 0,
                    photoBytes: 0,
                    videoBytes: 0,
                    audioBytes: 0,
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
                    finalStatus: state.outcome.statusString,
                    failurePhase: state.outcome.failurePhase,
                    failureReason: state.outcome.failureReason,
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
                ], flushPolicy: .deferred)
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
                finalStatus: state.outcome.statusString,
                dryRun: context.dryRun,
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
            try receiptWriter.append(eventType: .summary, phase: .finalize, data: summaryData, flushPolicy: .deferred)
            summaryEventWritten = true
        } catch {
            logger.error("receipt_summary_write_failed", metadata: [
                "session_id": context.sessionID,
                "error": error.localizedDescription,
            ])
        }

        var finishedData: [String: Any] = [
            "status": state.outcome.statusString,
            "dry_run": context.dryRun,
            "candidate_count": state.scanSummary?.candidates.count ?? 0,
            "error_count": state.outcomeTotals.errors,
            "receipt_path": receiptWriter.sink.path,
            "receipt_sink": receiptWriter.sink.kind.rawValue,
            "summary_event_written": summaryEventWritten,
            "path_scheme": context.pathSchemeString,
            "resume_hook": receiptWriter.resumeHook(),
        ]

        if case let .aborted(failurePhase, failureReason) = state.outcome {
            finishedData["failure_phase"] = failurePhase.rawValue
            finishedData["error"] = failureReason
        }

        do {
            try receiptWriter.append(eventType: .sessionFinished, phase: .finalize, data: finishedData, flushPolicy: .fullSync)
        } catch {
            try? receiptWriter.flush(fullSync: true)
            logger.error("receipt_session_finished_write_failed", metadata: [
                "session_id": context.sessionID,
                "error": error.localizedDescription,
            ])
        }
        state.phaseTimings.capture(.finalize, startedAt: finalizePhaseStartedAt)

        let counts = IngestCounts(
            candidates: state.scanSummary?.candidates.count ?? 0,
            photos: state.scanSummary?.photoCount ?? 0,
            videos: state.scanSummary?.videoCount ?? 0,
            audios: state.scanSummary?.audioCount ?? 0,
            copied: state.outcomeTotals.copied,
            verified: state.outcomeTotals.verified,
            committed: state.outcomeTotals.committed,
            duplicateNotCopied: state.outcomeTotals.duplicateNotCopied,
            conflictsRenamed: state.outcomeTotals.conflictsRenamed,
            errors: state.outcomeTotals.errors
        )

        return IngestSessionResult(
            sessionID: context.sessionID,
            finalStatus: state.outcome.statusString,
            dryRun: context.dryRun,
            receiptPath: receiptWriter.sink.path,
            receiptSink: receiptWriter.sink.kind.rawValue,
            stagingSessionPath: context.stagingSessionPath,
            pdfSummaryPath: state.pdfSummaryPath,
            failurePhase: state.outcome.failurePhase,
            failureReason: state.outcome.failureReason,
            firstErrors: state.firstErrors,
            phaseTimings: state.phaseTimings.allPhases(),
            counts: counts,
            idempotency: IngestIdempotency(finalStatus: state.outcome.statusString, dryRun: context.dryRun, counts: counts),
            filmModeExifApplied: state.filmModeExifApplied,
            filmModeExifSkipped: state.filmModeExifSkipped
        )
    }
}
