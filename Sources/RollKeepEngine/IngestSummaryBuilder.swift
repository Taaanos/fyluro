import Foundation
import RollKeepCore

extension IngestSession {
    func buildSummaryData(
        finalStatus: String,
        dryRun: Bool,
        commitStageCompleted: Bool,
        scanSummary: ScanSummary?,
        destinationPlan: DestinationPathPlanner.Plan?,
        cardAssessment: CameraCardAssessment?,
        outcomeTotals: ReceiptOutcomeTotals,
        touchedPaths: ReceiptTouchedPaths,
        receiptWriter: ReceiptWriter,
        pdfSummaryPath: String?,
        phaseTimings: PhaseTimingTracker,
        isoFormatter: ISO8601DateFormatter,
        pathSchemeString: String,
        filmModeOverride: FilmModeOverride? = nil,
        filmModeExifApplied: Int = 0,
        filmModeExifSkipped: Int = 0
    ) -> [String: Any] {
        let candidates = scanSummary?.candidates ?? []
        let dateRange = buildDateRange(candidates: candidates, formatter: isoFormatter)
        let phaseTimingsPayload = phaseTimings.allPhases().map { timing in
            [
                "phase": timing.phase.rawValue,
                "milliseconds": timing.milliseconds,
            ] as [String: Any]
        }
        let bytesProcessed = (scanSummary?.photoBytes ?? 0) + (scanSummary?.videoBytes ?? 0)
        let candidateFileCount = scanSummary?.candidates.count ?? 0
        let plannedFileCount = destinationPlan?.files.count ?? 0
        let totalDurationMs = phaseTimingsPayload.reduce(0) { partial, payload in
            partial + ((payload["milliseconds"] as? Int) ?? 0)
        }

        let cameraLabels = cardAssessment?.distribution.map { entry in
            [
                "label": entry.cameraLabel,
                "file_count": entry.fileCount,
            ] as [String: Any]
        } ?? []

        let perFileOutcomes = destinationPlan?.files.map { planned in
            let executed: Bool
            if dryRun {
                executed = false
            } else if planned.disposition == .duplicateNotCopied {
                executed = false
            } else if let stagingPath = planned.stagingPath {
                executed = touchedPaths.hasWrittenStagingFile(stagingPath) || touchedPaths.hasMoveFromStaging(stagingPath)
            } else {
                executed = false
            }

            var payload: [String: Any] = [
                "path": planned.candidate.relativePath,
                "source_path": planned.candidate.absolutePath,
                "media_type": planned.candidate.mediaType.rawValue,
                "outcome": planned.disposition.rawValue,
                "final_path": planned.finalPath,
                "executed": executed,
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
            "verified_ok": commitStageCompleted && outcomeTotals.copied == outcomeTotals.verified,
            "dry_run": dryRun,
            "totals_by_media_type": [
                "photos": scanSummary?.photoCount ?? 0,
                "videos": scanSummary?.videoCount ?? 0,
            ],
            "totals_by_outcome": [
                "copied": outcomeTotals.copied,
                "verified": outcomeTotals.verified,
                "committed": outcomeTotals.committed,
                "duplicate_not_copied": outcomeTotals.duplicateNotCopied,
                "conflicts_renamed": outcomeTotals.conflictsRenamed,
                "errors": outcomeTotals.errors,
                "planned_stage_and_commit": outcomeTotals.plannedStageAndCommit,
            ],
            "bytes_processed": bytesProcessed,
            "path_scheme": pathSchemeString,
            "date_range": dateRange,
            "known_camera_file_count": cardAssessment?.knownCameraFileCount ?? 0,
            "unknown_camera_file_count": cardAssessment?.unknownCameraFileCount ?? 0,
            "camera_labels": cameraLabels,
            "phase_timings_ms": phaseTimingsPayload,
            "receipt_paths": receiptWriter.receiptPaths.map { ["kind": $0.kind.rawValue, "path": $0.path] },
            "receipt_sink_transitions": receiptWriter.sinkTransitions.map(\.payload),
            "touched_paths": touchedPaths.payload(with: receiptWriter),
            "planned_file_count": plannedFileCount,
            "analysis": [
                "total_duration_ms": totalDurationMs,
                "total_size_bytes": bytesProcessed,
                "candidate_file_count": candidateFileCount,
                "planned_file_count": plannedFileCount,
                "phase_timings_ms": phaseTimingsPayload,
            ],
            "per_file_outcomes": perFileOutcomes,
            "pdf_summary_path": pdfSummaryPath ?? "not_written",
            "resume_hook": receiptWriter.resumeHook(),
            "film_mode": filmModeSummaryPayload(
                override: filmModeOverride,
                applied: filmModeExifApplied,
                skipped: filmModeExifSkipped
            ),
        ]
    }

    private func filmModeSummaryPayload(
        override: FilmModeOverride?,
        applied: Int,
        skipped: Int
    ) -> [String: Any] {
        guard let override else {
            return ["used": false]
        }
        var payload: [String: Any] = [
            "used": true,
            "year": override.year,
            "month": override.month,
            "camera": override.camera,
            "exif_applied_count": applied,
            "exif_skipped_count": skipped,
        ]
        if let filmStock = override.filmStock {
            payload["film_stock"] = filmStock
        }
        if let iso = override.iso {
            payload["iso"] = iso
        }
        return payload
    }
    func buildDateRange(candidates: [MediaCandidate], formatter: ISO8601DateFormatter) -> [String: Any] {
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
    func captureDateForSummary(_ candidate: MediaCandidate) -> Date {
        if let photoDate = candidate.photoMetadata?.captureDateTime {
            return photoDate
        }

        if let videoDate = candidate.videoMetadata?.captureDateTime {
            return videoDate
        }

        return candidate.mtime
    }
}
