import Foundation
import FyluroCore

func buildScanFileListEntries(
    summary: ScanSummary,
    plan: DestinationPathPlanner.Plan,
    cameraInferenceByPath: [String: CameraInference],
    preparation: IngestPreparation,
    isoFormatter: ISO8601DateFormatter
) -> [[String: Any]] {
    let plannedBySourcePath = Dictionary(uniqueKeysWithValues: plan.files.map { planned in
        (planned.candidate.absolutePath, planned)
    })

    return summary.candidates.map { candidate in
        var fileData: [String: Any] = [
            "path": candidate.relativePath,
            "media_type": candidate.mediaType.rawValue,
            "size_bytes": candidate.sizeBytes,
            "mtime": isoFormatter.string(from: candidate.mtime),
        ]
        let sidecarEntries = candidate.sidecars.map { sidecar in
            [
                "path": sidecar.relativePath,
                "source_path": sidecar.absolutePath,
                "size_bytes": sidecar.sizeBytes,
                "mtime": isoFormatter.string(from: sidecar.mtime),
                "extension": sidecar.fileExtension,
            ] as [String: Any]
        }
        fileData["sidecar_count"] = sidecarEntries.count
        if !sidecarEntries.isEmpty {
            fileData["sidecars"] = sidecarEntries
        }
        let inference = cameraInferenceByPath[candidate.absolutePath] ?? CameraInference(
            cameraLabel: "unknown-camera",
            make: nil,
            model: nil,
            serial: nil
        )
        let plannedFile = plannedBySourcePath[candidate.absolutePath]
        fileData["camera_label"] = inference.cameraLabel
        fileData["final_path"] = plannedFile?.finalPath ?? "missing"
        fileData["staging_path"] = plannedFile?.stagingPath ?? "duplicate_not_copied"
        fileData["plan_outcome"] = plannedFile?.disposition.rawValue ?? "missing"
        fileData["collision_renamed"] = plannedFile?.collisionResolved ?? false
        fileData["camera_evidence"] = preparation.cameraEvidencePayload(for: candidate)

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
}
