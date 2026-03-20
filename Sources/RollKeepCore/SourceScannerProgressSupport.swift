import Foundation

enum SourceScannerProgressPolicy {
    static let fileCheckInterval = 100
    static let timeInterval: TimeInterval = 0.75
}

struct SourceScannerProgressState {
    private var lastProgressEventAt: Date?
    private var lastProgressFilesChecked = 0

    mutating func shouldEmit(filesChecked: Int, force: Bool, now: Date = Date()) -> Bool {
        let shouldEmitOnInterval = filesChecked == 1
            || (filesChecked - lastProgressFilesChecked) >= SourceScannerProgressPolicy.fileCheckInterval
            || lastProgressEventAt.map { now.timeIntervalSince($0) >= SourceScannerProgressPolicy.timeInterval } == true

        guard force || shouldEmitOnInterval else {
            return false
        }

        lastProgressEventAt = now
        lastProgressFilesChecked = filesChecked
        return true
    }
}

struct SourceScannerProgressSnapshotCalculator {
    func makeProgressSnapshot(
        itemCount: Int,
        filesChecked: Int,
        photoCount: Int,
        videoCount: Int,
        photoBytes: Int64,
        videoBytes: Int64,
        bytesChecked: Int64,
        totalBytes: Int64,
        currentRelativePath: String?,
        cameraLabelCounts: [String: Int],
        cameraAssessmentOverride: CameraCardAssessment? = nil
    ) -> ScanProgressSnapshot {
        ScanProgressSnapshot(
            itemCount: itemCount,
            filesChecked: filesChecked,
            photoCount: photoCount,
            videoCount: videoCount,
            photoBytes: photoBytes,
            videoBytes: videoBytes,
            bytesChecked: bytesChecked,
            totalBytes: totalBytes,
            currentRelativePath: currentRelativePath,
            cameraAssessment: cameraAssessmentOverride ?? makeCameraAssessment(
                cameraLabelCounts: cameraLabelCounts,
                totalCandidates: itemCount
            )
        )
    }

    func makeCameraAssessment(
        cameraLabelCounts: [String: Int],
        totalCandidates: Int
    ) -> CameraCardAssessment {
        let distribution = cameraLabelCounts.map { label, count in
            CameraDistributionEntry(cameraLabel: label, fileCount: count)
        }.sorted { lhs, rhs in
            if lhs.fileCount != rhs.fileCount {
                return lhs.fileCount > rhs.fileCount
            }
            return lhs.cameraLabel < rhs.cameraLabel
        }

        let knownDistribution = distribution.filter { $0.cameraLabel != CameraLabeler.unknownLabel }
        let mixed = knownDistribution.count > 1
        let knownCount = knownDistribution.map(\.fileCount).reduce(0, +)
        let unknownCount = cameraLabelCounts[CameraLabeler.unknownLabel] ?? 0
        let dominantLabel = knownDistribution.first?.cameraLabel ?? CameraLabeler.unknownLabel

        return CameraCardAssessment(
            cameraLabel: mixed ? CameraLabeler.mixedLabel : dominantLabel,
            mixedCameraDetected: mixed,
            totalCandidates: totalCandidates,
            knownCameraFileCount: knownCount,
            unknownCameraFileCount: unknownCount,
            distribution: distribution
        )
    }
}
