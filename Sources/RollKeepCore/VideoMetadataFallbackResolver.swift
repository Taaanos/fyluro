import Foundation

struct VideoMetadataFallbackResolver {
    let embeddedFallbackMode: AVFoundationVideoMetadataExtractor.EmbeddedFallbackMode
    let parser: VideoCreationDateParser
    let sidecarMetadataExtractor: @Sendable (URL, VideoCreationDateParser) -> VideoMetadataSnapshot
    let embeddedMetadataExtractor: @Sendable (URL, VideoCreationDateParser) -> VideoMetadataSnapshot

    func resolveSidecarFallbackIfNeeded(primary: VideoMetadataSnapshot, fileURL: URL) -> VideoMetadataSnapshot {
        guard Self.requiresSidecarFallback(primary) else {
            return primary
        }

        let sidecarMetadata = sidecarMetadataExtractor(fileURL, parser)
        return VideoMetadataSnapshot(
            captureDateTime: primary.captureDateTime ?? sidecarMetadata.captureDateTime,
            captureDateSource: primary.captureDateSource ?? sidecarMetadata.captureDateSource,
            cameraMake: primary.cameraMake ?? sidecarMetadata.cameraMake,
            cameraModel: primary.cameraModel ?? sidecarMetadata.cameraModel,
            cameraSerial: primary.cameraSerial ?? sidecarMetadata.cameraSerial,
            cameraMakeSource: primary.cameraMakeSource ?? sidecarMetadata.cameraMakeSource,
            cameraModelSource: primary.cameraModelSource ?? sidecarMetadata.cameraModelSource,
            cameraSerialSource: primary.cameraSerialSource ?? sidecarMetadata.cameraSerialSource,
            cameraMakeSelectionRule: "first_non_empty_by_source_priority(primary,sidecar)",
            cameraModelSelectionRule: "first_non_empty_by_source_priority(primary,sidecar)",
            cameraSerialSelectionRule: "first_non_empty_by_source_priority(primary,sidecar)"
        )
    }

    func resolveEmbeddedFallbackIfNeeded(primary: VideoMetadataSnapshot, fileURL: URL) -> VideoMetadataSnapshot {
        guard embeddedFallbackMode != .disabled else {
            return primary
        }

        guard Self.requiresEmbeddedFallback(primary) else {
            return primary
        }

        let embeddedMetadata = embeddedMetadataExtractor(fileURL, parser)
        return VideoMetadataSnapshot(
            captureDateTime: primary.captureDateTime ?? embeddedMetadata.captureDateTime,
            captureDateSource: primary.captureDateSource ?? embeddedMetadata.captureDateSource,
            cameraMake: primary.cameraMake ?? embeddedMetadata.cameraMake,
            cameraModel: primary.cameraModel ?? embeddedMetadata.cameraModel,
            cameraSerial: primary.cameraSerial ?? embeddedMetadata.cameraSerial,
            cameraMakeSource: primary.cameraMakeSource ?? embeddedMetadata.cameraMakeSource,
            cameraModelSource: primary.cameraModelSource ?? embeddedMetadata.cameraModelSource,
            cameraSerialSource: primary.cameraSerialSource ?? embeddedMetadata.cameraSerialSource,
            cameraMakeSelectionRule: "first_non_empty_by_source_priority(primary,sidecar,embedded)",
            cameraModelSelectionRule: "first_non_empty_by_source_priority(primary,sidecar,embedded)",
            cameraSerialSelectionRule: "first_non_empty_by_source_priority(primary,sidecar,embedded)"
        )
    }

    static func requiresSidecarFallback(_ metadata: VideoMetadataSnapshot) -> Bool {
        metadata.captureDateTime == nil ||
            metadata.cameraMake == nil ||
            metadata.cameraModel == nil ||
            metadata.cameraSerial == nil
    }

    static func requiresEmbeddedFallback(_ metadata: VideoMetadataSnapshot) -> Bool {
        metadata.cameraMake == nil &&
            metadata.cameraModel == nil
    }
}
