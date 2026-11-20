import Foundation

struct VideoSidecarMetadataExtractor {
    private let photoMetadataExtractor: any PhotoMetadataExtracting

    init(photoMetadataExtractor: any PhotoMetadataExtracting = ImageIOPhotoMetadataExtractor()) {
        self.photoMetadataExtractor = photoMetadataExtractor
    }

    func extract(for videoURL: URL, parser: VideoCreationDateParser) -> VideoMetadataSnapshot {
        let sidecarURLs = MediaSidecarSupport.discoverSidecarURLs(for: videoURL)
        guard !sidecarURLs.isEmpty else {
            return VideoMetadataSnapshot(
                captureDateTime: nil,
                captureDateSource: nil,
                cameraMake: nil,
                cameraModel: nil,
                cameraSerial: nil
            )
        }

        var captureDateTime: Date?
        var cameraMake: String?
        var cameraModel: String?
        var cameraSerial: String?

        for sidecarURL in sidecarURLs {
            let ext = sidecarURL.pathExtension.lowercased()
            let snapshot: VideoMetadataSnapshot

            if ext == "thm" {
                let photoMetadata = photoMetadataExtractor.extract(from: sidecarURL)
                snapshot = VideoMetadataSnapshot(
                    captureDateTime: photoMetadata.captureDateTime,
                    captureDateSource: photoMetadata.captureDateTime == nil ? nil : .sidecarMetadata,
                    cameraMake: photoMetadata.cameraMake,
                    cameraModel: photoMetadata.cameraModel,
                    cameraSerial: photoMetadata.cameraSerial,
                    cameraMakeSource: photoMetadata.cameraMake == nil ? nil : .sidecarMetadataMake,
                    cameraModelSource: photoMetadata.cameraModel == nil ? nil : .sidecarMetadataModel,
                    cameraSerialSource: photoMetadata.cameraSerial == nil ? nil : .sidecarMetadataSerial,
                    cameraMakeSelectionRule: "sidecar_direct",
                    cameraModelSelectionRule: "sidecar_direct",
                    cameraSerialSelectionRule: "sidecar_direct"
                )
            } else {
                let parsed = EmbeddedVideoMetadataTextParser().extract(
                    from: sidecarURL,
                    parser: parser,
                    byteCount: 512 * 1024
                )
                snapshot = VideoMetadataSnapshot(
                    captureDateTime: parsed.captureDateTime,
                    captureDateSource: parsed.captureDateTime == nil ? nil : .sidecarMetadata,
                    cameraMake: parsed.cameraMake,
                    cameraModel: parsed.cameraModel,
                    cameraSerial: parsed.cameraSerial,
                    cameraMakeSource: parsed.cameraMake == nil ? nil : .sidecarMetadataMake,
                    cameraModelSource: parsed.cameraModel == nil ? nil : .sidecarMetadataModel,
                    cameraSerialSource: parsed.cameraSerial == nil ? nil : .sidecarMetadataSerial,
                    cameraMakeSelectionRule: "sidecar_direct",
                    cameraModelSelectionRule: "sidecar_direct",
                    cameraSerialSelectionRule: "sidecar_direct"
                )
            }

            if captureDateTime == nil {
                captureDateTime = snapshot.captureDateTime
            }
            if cameraMake == nil {
                cameraMake = snapshot.cameraMake
            }
            if cameraModel == nil {
                cameraModel = snapshot.cameraModel
            }
            if cameraSerial == nil {
                cameraSerial = snapshot.cameraSerial
            }

            if captureDateTime != nil && cameraMake != nil && cameraModel != nil && cameraSerial != nil {
                break
            }
        }

        return VideoMetadataSnapshot(
            captureDateTime: captureDateTime,
            captureDateSource: captureDateTime == nil ? nil : .sidecarMetadata,
            cameraMake: cameraMake,
            cameraModel: cameraModel,
            cameraSerial: cameraSerial,
            cameraMakeSource: cameraMake == nil ? nil : .sidecarMetadataMake,
            cameraModelSource: cameraModel == nil ? nil : .sidecarMetadataModel,
            cameraSerialSource: cameraSerial == nil ? nil : .sidecarMetadataSerial,
            cameraMakeSelectionRule: "first_non_empty_by_sidecar_order",
            cameraModelSelectionRule: "first_non_empty_by_sidecar_order",
            cameraSerialSelectionRule: "first_non_empty_by_sidecar_order"
        )
    }
}
