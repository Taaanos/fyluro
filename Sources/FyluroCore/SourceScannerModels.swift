import Foundation

public enum MediaType: String, Sendable {
    case photo
    case video
    case audio
}

public enum PhotoCaptureDateSource: String, Sendable {
    case dateTimeOriginal = "DateTimeOriginal"
    case createDate = "CreateDate"
    case mtimeFallback = "mtime_fallback"
    case filmModeOverride = "film_mode_override"
    case missing
}

public enum VideoCaptureDateSource: String, Sendable {
    case creationTime = "creation_time"
    case sidecarMetadata = "sidecar_metadata"
    case mtimeFallback = "mtime_fallback"
}

public enum AudioCaptureDateSource: String, Sendable {
    case creationTime = "creation_time"
    case mtimeFallback = "mtime_fallback"
}

public struct PhotoMetadata: Equatable, Sendable {
    public let captureDateTime: Date?
    public let captureDateSource: PhotoCaptureDateSource
    public let cameraMake: String?
    public let cameraModel: String?
    public let cameraSerial: String?
    let cameraEvidence: CameraIdentityEvidence?

    public init(
        captureDateTime: Date?,
        captureDateSource: PhotoCaptureDateSource,
        cameraMake: String?,
        cameraModel: String?,
        cameraSerial: String?
    ) {
        self.init(
            captureDateTime: captureDateTime,
            captureDateSource: captureDateSource,
            cameraMake: cameraMake,
            cameraModel: cameraModel,
            cameraSerial: cameraSerial,
            cameraEvidence: nil
        )
    }

    init(
        captureDateTime: Date?,
        captureDateSource: PhotoCaptureDateSource,
        cameraMake: String?,
        cameraModel: String?,
        cameraSerial: String?,
        cameraEvidence: CameraIdentityEvidence?
    ) {
        self.captureDateTime = captureDateTime
        self.captureDateSource = captureDateSource
        self.cameraMake = cameraMake
        self.cameraModel = cameraModel
        self.cameraSerial = cameraSerial
        self.cameraEvidence = cameraEvidence
    }

    public var planBucket: String {
        captureDateTime == nil ? "_unsorted" : "dated"
    }
}

public protocol PhotoMetadataExtracting {
    func extract(from fileURL: URL) -> PhotoMetadata
}

public protocol VideoMetadataExtracting {
    func extract(from fileURL: URL, fallbackMtime: Date) -> VideoMetadata
}

public protocol AudioMetadataExtracting {
    func extract(from fileURL: URL, fallbackMtime: Date) -> AudioMetadata
}

public struct AudioMetadata: Equatable, Sendable {
    public let captureDateTime: Date
    public let captureDateSource: AudioCaptureDateSource
    public let usedFallback: Bool

    public init(
        captureDateTime: Date,
        captureDateSource: AudioCaptureDateSource,
        usedFallback: Bool
    ) {
        self.captureDateTime = captureDateTime
        self.captureDateSource = captureDateSource
        self.usedFallback = usedFallback
    }
}

public struct VideoMetadata: Equatable, Sendable {
    public let captureDateTime: Date
    public let captureDateSource: VideoCaptureDateSource
    public let usedFallback: Bool
    public let cameraMake: String?
    public let cameraModel: String?
    public let cameraSerial: String?
    let cameraEvidence: CameraIdentityEvidence?

    public init(
        captureDateTime: Date,
        captureDateSource: VideoCaptureDateSource,
        usedFallback: Bool,
        cameraMake: String? = nil,
        cameraModel: String? = nil,
        cameraSerial: String? = nil
    ) {
        self.init(
            captureDateTime: captureDateTime,
            captureDateSource: captureDateSource,
            usedFallback: usedFallback,
            cameraMake: cameraMake,
            cameraModel: cameraModel,
            cameraSerial: cameraSerial,
            cameraEvidence: nil
        )
    }

    init(
        captureDateTime: Date,
        captureDateSource: VideoCaptureDateSource,
        usedFallback: Bool,
        cameraMake: String? = nil,
        cameraModel: String? = nil,
        cameraSerial: String? = nil,
        cameraEvidence: CameraIdentityEvidence?
    ) {
        self.captureDateTime = captureDateTime
        self.captureDateSource = captureDateSource
        self.usedFallback = usedFallback
        self.cameraMake = cameraMake
        self.cameraModel = cameraModel
        self.cameraSerial = cameraSerial
        self.cameraEvidence = cameraEvidence
    }
}

public struct MediaCandidate: Equatable, Sendable {
    public let absolutePath: String
    public let relativePath: String
    public let mediaType: MediaType
    public let sizeBytes: Int64
    public let mtime: Date
    public let creationDate: Date?
    public let photoMetadata: PhotoMetadata?
    public let videoMetadata: VideoMetadata?
    public let audioMetadata: AudioMetadata?
    public let sidecars: [MediaSidecar]

    public init(
        absolutePath: String,
        relativePath: String,
        mediaType: MediaType,
        sizeBytes: Int64,
        mtime: Date,
        creationDate: Date? = nil,
        photoMetadata: PhotoMetadata? = nil,
        videoMetadata: VideoMetadata? = nil,
        audioMetadata: AudioMetadata? = nil,
        sidecars: [MediaSidecar] = []
    ) {
        self.absolutePath = absolutePath
        self.relativePath = relativePath
        self.mediaType = mediaType
        self.sizeBytes = sizeBytes
        self.mtime = mtime
        self.creationDate = creationDate
        self.photoMetadata = photoMetadata
        self.videoMetadata = videoMetadata
        self.audioMetadata = audioMetadata
        self.sidecars = sidecars
    }
}

public struct ScanErrorRecord: Equatable, Sendable {
    public let path: String
    public let message: String

    public init(path: String, message: String) {
        self.path = path
        self.message = message
    }
}

public enum ScanWarningCategory: String, Equatable, Sendable {
    case unknownLargeSkippedFile = "unknown_large_skipped_file"
    case symbolicLinkSkipped = "symbolic_link_skipped"
}

public struct ScanWarningRecord: Equatable, Sendable {
    public let path: String
    public let message: String
    public let fileExtension: String
    public let sizeBytes: Int64
    public let category: ScanWarningCategory

    public init(
        path: String,
        message: String,
        fileExtension: String,
        sizeBytes: Int64,
        category: ScanWarningCategory = .unknownLargeSkippedFile
    ) {
        self.path = path
        self.message = message
        self.fileExtension = fileExtension
        self.sizeBytes = sizeBytes
        self.category = category
    }
}

public struct ScanProgressSnapshot: Equatable, Sendable {
    public let itemCount: Int
    public let filesChecked: Int
    public let photoCount: Int
    public let videoCount: Int
    public let audioCount: Int
    public let photoBytes: Int64
    public let videoBytes: Int64
    public let audioBytes: Int64
    public let bytesChecked: Int64
    public let totalBytes: Int64
    public let currentRelativePath: String?
    public let cameraAssessment: CameraCardAssessment

    public init(
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
        cameraAssessment: CameraCardAssessment
    ) {
        self.itemCount = itemCount
        self.filesChecked = filesChecked
        self.photoCount = photoCount
        self.videoCount = videoCount
        self.audioCount = audioCount
        self.photoBytes = photoBytes
        self.videoBytes = videoBytes
        self.audioBytes = audioBytes
        self.bytesChecked = bytesChecked
        self.totalBytes = totalBytes
        self.currentRelativePath = currentRelativePath
        self.cameraAssessment = cameraAssessment
    }
}

public struct ScanSummary: Equatable, Sendable {
    public let candidates: [MediaCandidate]
    public let photoCount: Int
    public let videoCount: Int
    public let audioCount: Int
    public let photoBytes: Int64
    public let videoBytes: Int64
    public let audioBytes: Int64
    public let filesInTypicalLocations: Int
    public let filesOutsideTypicalLocations: Int
    public let errors: [ScanErrorRecord]
    public let warnings: [ScanWarningRecord]
    public let cameraAssessment: CameraCardAssessment

    public init(
        candidates: [MediaCandidate],
        photoCount: Int,
        videoCount: Int,
        audioCount: Int = 0,
        photoBytes: Int64,
        videoBytes: Int64,
        audioBytes: Int64 = 0,
        filesInTypicalLocations: Int,
        filesOutsideTypicalLocations: Int,
        errors: [ScanErrorRecord],
        warnings: [ScanWarningRecord] = [],
        cameraAssessment: CameraCardAssessment? = nil
    ) {
        self.candidates = candidates
        self.photoCount = photoCount
        self.videoCount = videoCount
        self.audioCount = audioCount
        self.photoBytes = photoBytes
        self.videoBytes = videoBytes
        self.audioBytes = audioBytes
        self.filesInTypicalLocations = filesInTypicalLocations
        self.filesOutsideTypicalLocations = filesOutsideTypicalLocations
        self.errors = errors
        self.warnings = warnings
        self.cameraAssessment = cameraAssessment ?? CameraLabeler().assessCard(candidates: candidates)
    }

    // Deduplicates by path to match IngestPreparationService when RAW and JPEG share a sidecar.
    public var sidecarCount: Int {
        var seenPaths: Set<String> = []
        for candidate in candidates {
            for sidecar in candidate.sidecars {
                seenPaths.insert(sidecar.absolutePath)
            }
        }
        return seenPaths.count
    }
}

public enum SourceScannerError: Error, Equatable, Sendable {
    case unreadableSourceRoot(String)
    case sourceBoundaryViolation(path: String, sourceRoot: String)
}

public enum SourceScanMode: String, Sendable {
    case preview
    case deep
}
