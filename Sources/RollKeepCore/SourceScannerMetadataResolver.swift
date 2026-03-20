import Foundation

struct SourceScannerMetadataResolver {
    private let photoMetadataExtractor: any PhotoMetadataExtracting
    private let videoMetadataExtractor: any VideoMetadataExtracting
    private let previewVideoMetadataExtractor: any VideoMetadataExtracting
    private let forcedMissingCaptureDateRelativePaths: Set<String>

    init(
        photoMetadataExtractor: any PhotoMetadataExtracting,
        videoMetadataExtractor: any VideoMetadataExtracting,
        previewVideoMetadataExtractor: any VideoMetadataExtracting,
        forcedMissingCaptureDateRelativePaths: Set<String>
    ) {
        self.photoMetadataExtractor = photoMetadataExtractor
        self.videoMetadataExtractor = videoMetadataExtractor
        self.previewVideoMetadataExtractor = previewVideoMetadataExtractor
        self.forcedMissingCaptureDateRelativePaths = forcedMissingCaptureDateRelativePaths
    }

    func resolve(
        mediaType: MediaType,
        fileURL: URL,
        relativePath: String,
        fallbackMtime: Date,
        mode: SourceScanMode
    ) -> (photoMetadata: PhotoMetadata?, videoMetadata: VideoMetadata?) {
        var photoMetadata = mediaType == .photo
            ? resolvedPhotoMetadata(from: fileURL, fallbackMtime: fallbackMtime)
            : nil
        var videoMetadata: VideoMetadata?

        if mediaType == .video {
            switch mode {
            case .preview:
                videoMetadata = previewVideoMetadataExtractor.extract(from: fileURL, fallbackMtime: fallbackMtime)
            case .deep:
                videoMetadata = videoMetadataExtractor.extract(from: fileURL, fallbackMtime: fallbackMtime)
            }
        }

        applyForcedMissingCaptureDateIfNeeded(
            relativePath: relativePath,
            mediaType: mediaType,
            photoMetadata: &photoMetadata,
            videoMetadata: &videoMetadata
        )

        return (photoMetadata: photoMetadata, videoMetadata: videoMetadata)
    }

    private func resolvedPhotoMetadata(from fileURL: URL, fallbackMtime: Date) -> PhotoMetadata {
        let extracted = photoMetadataExtractor.extract(from: fileURL)
        guard extracted.captureDateTime == nil else {
            return extracted
        }

        return PhotoMetadata(
            captureDateTime: fallbackMtime,
            captureDateSource: .mtimeFallback,
            cameraMake: extracted.cameraMake,
            cameraModel: extracted.cameraModel,
            cameraSerial: extracted.cameraSerial,
            cameraEvidence: extracted.cameraEvidence
        )
    }

    private func applyForcedMissingCaptureDateIfNeeded(
        relativePath: String,
        mediaType: MediaType,
        photoMetadata: inout PhotoMetadata?,
        videoMetadata: inout VideoMetadata?
    ) {
        guard forcedMissingCaptureDateRelativePaths.contains(relativePath) else {
            return
        }

        // Test-only hook: allow deterministic _unsorted E2E coverage without mutating fixture metadata.
        if let metadata = photoMetadata {
            photoMetadata = PhotoMetadata(
                captureDateTime: nil,
                captureDateSource: .missing,
                cameraMake: metadata.cameraMake,
                cameraModel: metadata.cameraModel,
                cameraSerial: metadata.cameraSerial,
                cameraEvidence: metadata.cameraEvidence
            )
        }
        if mediaType == .video {
            videoMetadata = nil
        }
    }
}
