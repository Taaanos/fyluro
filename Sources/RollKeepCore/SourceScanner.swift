import Foundation

public enum MediaType: String, Sendable {
    case photo
    case video
}

public enum PhotoCaptureDateSource: String, Sendable {
    case dateTimeOriginal = "DateTimeOriginal"
    case createDate = "CreateDate"
    case missing
}

public enum VideoCaptureDateSource: String, Sendable {
    case creationTime = "creation_time"
    case mtimeFallback = "mtime_fallback"
}

public struct PhotoMetadata: Equatable, Sendable {
    public let captureDateTime: Date?
    public let captureDateSource: PhotoCaptureDateSource
    public let cameraMake: String?
    public let cameraModel: String?
    public let cameraSerial: String?

    public init(
        captureDateTime: Date?,
        captureDateSource: PhotoCaptureDateSource,
        cameraMake: String?,
        cameraModel: String?,
        cameraSerial: String?
    ) {
        self.captureDateTime = captureDateTime
        self.captureDateSource = captureDateSource
        self.cameraMake = cameraMake
        self.cameraModel = cameraModel
        self.cameraSerial = cameraSerial
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

public struct VideoMetadata: Equatable, Sendable {
    public let captureDateTime: Date
    public let captureDateSource: VideoCaptureDateSource
    public let usedFallback: Bool
    public let cameraMake: String?
    public let cameraModel: String?
    public let cameraSerial: String?

    public init(
        captureDateTime: Date,
        captureDateSource: VideoCaptureDateSource,
        usedFallback: Bool,
        cameraMake: String? = nil,
        cameraModel: String? = nil,
        cameraSerial: String? = nil
    ) {
        self.captureDateTime = captureDateTime
        self.captureDateSource = captureDateSource
        self.usedFallback = usedFallback
        self.cameraMake = cameraMake
        self.cameraModel = cameraModel
        self.cameraSerial = cameraSerial
    }
}

public struct MediaCandidate: Equatable, Sendable {
    public let absolutePath: String
    public let relativePath: String
    public let mediaType: MediaType
    public let sizeBytes: Int64
    public let mtime: Date
    public let photoMetadata: PhotoMetadata?
    public let videoMetadata: VideoMetadata?

    public init(
        absolutePath: String,
        relativePath: String,
        mediaType: MediaType,
        sizeBytes: Int64,
        mtime: Date,
        photoMetadata: PhotoMetadata? = nil,
        videoMetadata: VideoMetadata? = nil
    ) {
        self.absolutePath = absolutePath
        self.relativePath = relativePath
        self.mediaType = mediaType
        self.sizeBytes = sizeBytes
        self.mtime = mtime
        self.photoMetadata = photoMetadata
        self.videoMetadata = videoMetadata
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

public struct ScanProgressSnapshot: Equatable, Sendable {
    public let itemCount: Int
    public let photoCount: Int
    public let videoCount: Int
    public let totalBytes: Int64
    public let cameraAssessment: CameraCardAssessment

    public init(
        itemCount: Int,
        photoCount: Int,
        videoCount: Int,
        totalBytes: Int64,
        cameraAssessment: CameraCardAssessment
    ) {
        self.itemCount = itemCount
        self.photoCount = photoCount
        self.videoCount = videoCount
        self.totalBytes = totalBytes
        self.cameraAssessment = cameraAssessment
    }
}

public struct ScanSummary: Equatable, Sendable {
    public let candidates: [MediaCandidate]
    public let photoCount: Int
    public let videoCount: Int
    public let photoBytes: Int64
    public let videoBytes: Int64
    public let filesInTypicalLocations: Int
    public let filesOutsideTypicalLocations: Int
    public let errors: [ScanErrorRecord]
    public let cameraAssessment: CameraCardAssessment

    public init(
        candidates: [MediaCandidate],
        photoCount: Int,
        videoCount: Int,
        photoBytes: Int64,
        videoBytes: Int64,
        filesInTypicalLocations: Int,
        filesOutsideTypicalLocations: Int,
        errors: [ScanErrorRecord],
        cameraAssessment: CameraCardAssessment? = nil
    ) {
        self.candidates = candidates
        self.photoCount = photoCount
        self.videoCount = videoCount
        self.photoBytes = photoBytes
        self.videoBytes = videoBytes
        self.filesInTypicalLocations = filesInTypicalLocations
        self.filesOutsideTypicalLocations = filesOutsideTypicalLocations
        self.errors = errors
        self.cameraAssessment = cameraAssessment ?? CameraLabeler().assessCard(candidates: candidates)
    }
}

public enum SourceScannerError: Error, Equatable, Sendable {
    case unreadableSourceRoot(String)
}

public struct SourceScanner {
    private let fileManager: FileManager
    private let photoMetadataExtractor: any PhotoMetadataExtracting
    private let videoMetadataExtractor: any VideoMetadataExtracting
    private let cameraLabeler = CameraLabeler()

    public init(
        fileManager: FileManager = .default,
        photoMetadataExtractor: any PhotoMetadataExtracting = ImageIOPhotoMetadataExtractor(),
        videoMetadataExtractor: any VideoMetadataExtracting = AVFoundationVideoMetadataExtractor()
    ) {
        self.fileManager = fileManager
        self.photoMetadataExtractor = photoMetadataExtractor
        self.videoMetadataExtractor = videoMetadataExtractor
    }

    public func scan(
        sourceRoot: URL,
        progress: (@Sendable (ScanProgressSnapshot) -> Void)? = nil
    ) throws -> ScanSummary {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: sourceRoot.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              fileManager.isReadableFile(atPath: sourceRoot.path)
        else {
            throw SourceScannerError.unreadableSourceRoot(sourceRoot.path)
        }

        var candidates: [MediaCandidate] = []
        var errors: [ScanErrorRecord] = []
        var photoCount = 0
        var videoCount = 0
        var photoBytes: Int64 = 0
        var videoBytes: Int64 = 0
        var filesInTypicalLocations = 0

        let keys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .isRegularFileKey,
            .isReadableKey,
            .isHiddenKey,
            .fileSizeKey,
            .contentModificationDateKey,
        ]

        guard let enumerator = fileManager.enumerator(
            at: sourceRoot,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsPackageDescendants],
            errorHandler: { url, error in
                errors.append(ScanErrorRecord(path: url.path, message: error.localizedDescription))
                return true
            }
        ) else {
            throw SourceScannerError.unreadableSourceRoot(sourceRoot.path)
        }

        while let url = enumerator.nextObject() as? URL {
            do {
                let resourceValues = try url.resourceValues(forKeys: keys)

                if shouldExclude(url: url, values: resourceValues, sourceRoot: sourceRoot) {
                    if resourceValues.isDirectory == true {
                        enumerator.skipDescendants()
                    }
                    continue
                }

                guard resourceValues.isRegularFile == true else {
                    continue
                }

                guard resourceValues.isReadable != false else {
                    errors.append(ScanErrorRecord(path: url.path, message: "File is not readable"))
                    continue
                }

                guard let mediaType = detectMediaType(for: url) else {
                    continue
                }

                guard let fileSize = resourceValues.fileSize else {
                    errors.append(ScanErrorRecord(path: url.path, message: "Unable to read file size"))
                    continue
                }

                let mtime = resourceValues.contentModificationDate ?? Date(timeIntervalSince1970: 0)
                let relativePath = normalizeRelativePath(url: url, sourceRoot: sourceRoot)
                let photoMetadata = mediaType == .photo ? photoMetadataExtractor.extract(from: url) : nil
                let videoMetadata = mediaType == .video
                    ? videoMetadataExtractor.extract(from: url, fallbackMtime: mtime)
                    : nil

                candidates.append(MediaCandidate(
                    absolutePath: url.path,
                    relativePath: relativePath,
                    mediaType: mediaType,
                    sizeBytes: Int64(fileSize),
                    mtime: mtime,
                    photoMetadata: photoMetadata,
                    videoMetadata: videoMetadata
                ))

                switch mediaType {
                case .photo:
                    photoCount += 1
                    photoBytes += Int64(fileSize)
                case .video:
                    videoCount += 1
                    videoBytes += Int64(fileSize)
                }

                if isInTypicalMediaLocation(relativePath: relativePath) {
                    filesInTypicalLocations += 1
                }

                let detectedMediaCount = photoCount + videoCount
                if detectedMediaCount == 1 || detectedMediaCount % 10 == 0 {
                    progress?(makeProgressSnapshot(
                        candidates: candidates,
                        photoCount: photoCount,
                        videoCount: videoCount,
                        totalBytes: photoBytes + videoBytes
                    ))
                }
            } catch {
                errors.append(ScanErrorRecord(path: url.path, message: error.localizedDescription))
            }
        }

        candidates.sort { lhs, rhs in
            let leftKey = lhs.relativePath.lowercased()
            let rightKey = rhs.relativePath.lowercased()
            if leftKey != rightKey {
                return leftKey < rightKey
            }
            if lhs.relativePath != rhs.relativePath {
                return lhs.relativePath < rhs.relativePath
            }
            return lhs.absolutePath < rhs.absolutePath
        }

        let summary = ScanSummary(
            candidates: candidates,
            photoCount: photoCount,
            videoCount: videoCount,
            photoBytes: photoBytes,
            videoBytes: videoBytes,
            filesInTypicalLocations: filesInTypicalLocations,
            filesOutsideTypicalLocations: candidates.count - filesInTypicalLocations,
            errors: errors
        )
        progress?(ScanProgressSnapshot(
            itemCount: summary.candidates.count,
            photoCount: summary.photoCount,
            videoCount: summary.videoCount,
            totalBytes: summary.photoBytes + summary.videoBytes,
            cameraAssessment: summary.cameraAssessment
        ))
        return summary
    }

    private func detectMediaType(for url: URL) -> MediaType? {
        let ext = url.pathExtension.lowercased()

        if Self.photoExtensions.contains(ext) {
            return .photo
        }

        if Self.videoExtensions.contains(ext) {
            return .video
        }

        return nil
    }

    private func normalizeRelativePath(url: URL, sourceRoot: URL) -> String {
        let sourcePath = sourceRoot.standardizedFileURL.path
        let fullPath = url.standardizedFileURL.path

        guard fullPath.hasPrefix(sourcePath) else {
            return url.lastPathComponent
        }

        let start = fullPath.index(fullPath.startIndex, offsetBy: sourcePath.count)
        let suffix = String(fullPath[start...])
        return suffix.hasPrefix("/") ? String(suffix.dropFirst()) : suffix
    }

    private func shouldExclude(url: URL, values: URLResourceValues, sourceRoot: URL) -> Bool {
        if values.isHidden == true {
            return true
        }

        let relativePath = normalizeRelativePath(url: url, sourceRoot: sourceRoot)
        if relativePath.isEmpty {
            return false
        }

        let components = relativePath.split(separator: "/").map(String.init)
        for component in components {
            if component.hasPrefix(".") {
                return true
            }

            if Self.systemEntries.contains(component.lowercased()) {
                return true
            }
        }

        return false
    }

    private static let systemEntries: Set<String> = [
        "$recycle.bin",
        "system volume information",
        "__macosx",
    ]

    private static let photoExtensions: Set<String> = [
        "jpg", "jpeg", "png", "tif", "tiff", "heic", "heif", "gif", "bmp", "dng",
        "cr2", "cr3", "nef", "arw", "orf", "raf", "rw2", "srw", "pef", "x3f", "iiq",
    ]

    private static let videoExtensions: Set<String> = [
        "mov", "mp4", "m4v", "avi", "mpg", "mpeg", "mts", "m2ts", "mxf", "3gp", "3g2",
        "lrv", "mkv", "insv",
    ]

    private func isInTypicalMediaLocation(relativePath: String) -> Bool {
        let upperPath = relativePath.uppercased()
        return Self.typicalMediaRootPrefixes.contains(where: { upperPath.hasPrefix($0) })
    }

    private static let typicalMediaRootPrefixes: [String] = [
        "DCIM/",
        "PRIVATE/",
        "AVCHD/",
        "MP_ROOT/",
        "MISC/",
        "MOVIE/",
        "VIDEO/",
    ]

    private func makeProgressSnapshot(
        candidates: [MediaCandidate],
        photoCount: Int,
        videoCount: Int,
        totalBytes: Int64
    ) -> ScanProgressSnapshot {
        ScanProgressSnapshot(
            itemCount: photoCount + videoCount,
            photoCount: photoCount,
            videoCount: videoCount,
            totalBytes: totalBytes,
            cameraAssessment: cameraLabeler.assessCard(candidates: candidates)
        )
    }
}
