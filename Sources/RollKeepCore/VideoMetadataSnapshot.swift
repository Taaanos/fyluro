import Foundation

struct VideoMetadataSnapshot {
    let captureDateTime: Date?
    let captureDateSource: VideoCaptureDateSource?
    let cameraMake: String?
    let cameraModel: String?
    let cameraSerial: String?
    let cameraMakeSource: CameraIdentityEvidenceSource?
    let cameraModelSource: CameraIdentityEvidenceSource?
    let cameraSerialSource: CameraIdentityEvidenceSource?
    let cameraMakeSelectionRule: String
    let cameraModelSelectionRule: String
    let cameraSerialSelectionRule: String

    init(
        captureDateTime: Date?,
        captureDateSource: VideoCaptureDateSource? = nil,
        cameraMake: String?,
        cameraModel: String?,
        cameraSerial: String?,
        cameraMakeSource: CameraIdentityEvidenceSource? = nil,
        cameraModelSource: CameraIdentityEvidenceSource? = nil,
        cameraSerialSource: CameraIdentityEvidenceSource? = nil,
        cameraMakeSelectionRule: String = "unresolved",
        cameraModelSelectionRule: String = "unresolved",
        cameraSerialSelectionRule: String = "unresolved"
    ) {
        self.captureDateTime = captureDateTime
        self.captureDateSource = captureDateSource
        self.cameraMake = cameraMake
        self.cameraModel = cameraModel
        self.cameraSerial = cameraSerial
        self.cameraMakeSource = cameraMakeSource
        self.cameraModelSource = cameraModelSource
        self.cameraSerialSource = cameraSerialSource
        self.cameraMakeSelectionRule = cameraMakeSelectionRule
        self.cameraModelSelectionRule = cameraModelSelectionRule
        self.cameraSerialSelectionRule = cameraSerialSelectionRule
    }
}
