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

    func alreadyEmitted(forFilesChecked filesChecked: Int) -> Bool {
        lastProgressFilesChecked == filesChecked
    }
}

struct SourceScannerProgressSnapshotCalculator {
    func makeProgressSnapshot(
        itemCount: Int,
        filesChecked: Int,
        photoCount: Int,
        videoCount: Int,
        audioCount: Int = 0,
        photoBytes: Int64,
        videoBytes: Int64,
        audioBytes: Int64 = 0,
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
            audioCount: audioCount,
            photoBytes: photoBytes,
            videoBytes: videoBytes,
            audioBytes: audioBytes,
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
        let knownCount = knownDistribution.map(\.fileCount).reduce(0, +)
        let unknownCount = cameraLabelCounts[CameraLabeler.unknownLabel] ?? 0

        return CameraCardAssessment(
            totalCandidates: totalCandidates,
            knownCameraFileCount: knownCount,
            unknownCameraFileCount: unknownCount,
            distribution: distribution
        )
    }
}
