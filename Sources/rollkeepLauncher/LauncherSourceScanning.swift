import Foundation
import RollKeepCore

struct LauncherSourceScopeSummary: Equatable {
    let itemCount: Int
    let photoCount: Int
    let videoCount: Int
    let totalBytes: Int64
    let unsortedCount: Int
    let cameraEntries: [LauncherSourceCameraSummary]

    init(
        itemCount: Int,
        photoCount: Int,
        videoCount: Int,
        totalBytes: Int64,
        unsortedCount: Int = 0,
        cameraEntries: [LauncherSourceCameraSummary] = []
    ) {
        self.itemCount = itemCount
        self.photoCount = photoCount
        self.videoCount = videoCount
        self.totalBytes = totalBytes
        self.unsortedCount = max(0, unsortedCount)
        self.cameraEntries = cameraEntries
    }

    init(snapshot: ScanProgressSnapshot) {
        self.init(
            itemCount: snapshot.itemCount,
            photoCount: snapshot.photoCount,
            videoCount: snapshot.videoCount,
            totalBytes: snapshot.totalBytes,
            unsortedCount: 0,
            cameraEntries: Self.cameraEntries(from: snapshot.cameraAssessment)
        )
    }

    init(summary: ScanSummary) {
        self.init(
            itemCount: summary.candidates.count,
            photoCount: summary.photoCount,
            videoCount: summary.videoCount,
            totalBytes: summary.photoBytes + summary.videoBytes,
            unsortedCount: Self.unsortedCount(from: summary.candidates),
            cameraEntries: Self.cameraEntries(from: summary.cameraAssessment)
        )
    }

    init(preparation: IngestPreparation) {
        self.init(
            itemCount: preparation.scanSummary.candidates.count,
            photoCount: preparation.scanSummary.photoCount,
            videoCount: preparation.scanSummary.videoCount,
            totalBytes: preparation.scanSummary.photoBytes + preparation.scanSummary.videoBytes,
            unsortedCount: Self.unsortedCount(from: preparation.scanSummary.candidates),
            cameraEntries: Self.cameraEntries(from: preparation.cameraAssessment)
        )
    }

    var mediaDescription: String {
        switch (photoCount > 0, videoCount > 0) {
        case (true, true):
            return "Photos and videos"
        case (true, false):
            return "Photos"
        case (false, true):
            return "Videos"
        default:
            return "No media found"
        }
    }

    var detectedCameraCount: Int {
        cameraEntries.filter { !$0.isUnknown }.count
    }

    var unsortedWarningText: String? {
        guard unsortedCount > 0 else {
            return nil
        }

        let noun = unsortedCount == 1 ? "item" : "items"
        return "\(unsortedCount) \(noun) will be placed in _unsorted because capture date metadata is missing."
    }

    private static func cameraEntries(from assessment: CameraCardAssessment) -> [LauncherSourceCameraSummary] {
        assessment.distribution.map { entry in
            LauncherSourceCameraSummary(label: entry.cameraLabel, fileCount: entry.fileCount)
        }
    }

    private static func unsortedCount(from candidates: [MediaCandidate]) -> Int {
        candidates.reduce(0) { partial, candidate in
            let hasCaptureDate: Bool
            switch candidate.mediaType {
            case .photo:
                hasCaptureDate = candidate.photoMetadata?.captureDateTime != nil
            case .video:
                hasCaptureDate = candidate.videoMetadata?.captureDateTime != nil
            }

            return partial + (hasCaptureDate ? 0 : 1)
        }
    }
}

struct LauncherSourceCameraSummary: Equatable, Identifiable {
    let label: String
    let fileCount: Int

    var id: String { label }

    var isUnknown: Bool {
        label == CameraLabeler.unknownLabel
    }

    var displayLabel: String {
        isUnknown ? "Unknown camera" : label
    }
}

protocol LauncherSourceScanning: Sendable {
    func scan(
        sourcePath: String,
        mode: SourceScanMode,
        metadataCache: (any SourceScanMetadataCaching)?,
        progress: (@Sendable (ScanProgressSnapshot) -> Void)?
    ) throws -> IngestPreparation
}

struct LauncherSharedSourceScanner: LauncherSourceScanning {
    func scan(
        sourcePath: String,
        mode: SourceScanMode = .deep,
        metadataCache: (any SourceScanMetadataCaching)? = nil,
        progress: (@Sendable (ScanProgressSnapshot) -> Void)? = nil
    ) throws -> IngestPreparation {
        try IngestPreparationService().scan(
            sourceRoot: URL(fileURLWithPath: sourcePath, isDirectory: true),
            mode: mode,
            metadataCache: metadataCache,
            progress: progress
        )
    }
}

