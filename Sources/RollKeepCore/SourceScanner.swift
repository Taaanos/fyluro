import Foundation

public enum MediaType: String, Sendable {
    case photo
    case video
}

public enum PhotoCaptureDateSource: String, Sendable {
    case dateTimeOriginal = "DateTimeOriginal"
    case createDate = "CreateDate"
    case mtimeFallback = "mtime_fallback"
    case missing
}

public enum VideoCaptureDateSource: String, Sendable {
    case creationTime = "creation_time"
    case sidecarMetadata = "sidecar_metadata"
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
    public let creationDate: Date?
    public let photoMetadata: PhotoMetadata?
    public let videoMetadata: VideoMetadata?
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
    case symbolicLinkDetected(String)
    case sourceBoundaryViolation(path: String, sourceRoot: String)
}

public enum SourceScanMode: String, Sendable {
    case preview
    case deep
}

public struct SourceScanner {
    private let fileManager: FileManager
    private let photoMetadataExtractor: any PhotoMetadataExtracting
    private let videoMetadataExtractor: any VideoMetadataExtracting
    private let previewVideoMetadataExtractor: any VideoMetadataExtracting
    private let cameraLabeler = CameraLabeler()

    public init(
        fileManager: FileManager = .default,
        photoMetadataExtractor: any PhotoMetadataExtracting = ImageIOPhotoMetadataExtractor(),
        videoMetadataExtractor: any VideoMetadataExtracting = AVFoundationVideoMetadataExtractor(),
        previewVideoMetadataExtractor: any VideoMetadataExtracting = AVFoundationVideoMetadataExtractor(embeddedFallbackMode: .disabled)
    ) {
        self.fileManager = fileManager
        self.photoMetadataExtractor = photoMetadataExtractor
        self.videoMetadataExtractor = videoMetadataExtractor
        self.previewVideoMetadataExtractor = previewVideoMetadataExtractor
    }

    public func scan(
        sourceRoot: URL,
        mode: SourceScanMode = .deep,
        progress: (@Sendable (ScanProgressSnapshot) -> Void)? = nil
    ) throws -> ScanSummary {
        let canonicalSourceRootURL = sourceRoot
            .resolvingSymlinksInPath()
            .standardizedFileURL
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: canonicalSourceRootURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              fileManager.isReadableFile(atPath: canonicalSourceRootURL.path)
        else {
            throw SourceScannerError.unreadableSourceRoot(sourceRoot.path)
        }
        let sourceRootComponents = canonicalSourceRootURL.pathComponents

        var candidates: [MediaCandidate] = []
        var errors: [ScanErrorRecord] = []
        var photoCount = 0
        var videoCount = 0
        var photoBytes: Int64 = 0
        var videoBytes: Int64 = 0
        var filesInTypicalLocations = 0
        var cameraLabelCounts: [String: Int] = [:]
        var siblingURLCache: [String: [URL]] = [:]

        let keys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .isReadableKey,
            .isHiddenKey,
            .fileSizeKey,
            .contentModificationDateKey,
        ]

        guard let enumerator = fileManager.enumerator(
            at: canonicalSourceRootURL,
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
                if resourceValues.isSymbolicLink == true {
                    throw SourceScannerError.symbolicLinkDetected(url.path)
                }

                let resolvedURL = url
                    .resolvingSymlinksInPath()
                    .standardizedFileURL
                let relativePath = try normalizeRelativePath(
                    url: resolvedURL,
                    canonicalSourceRootURL: canonicalSourceRootURL,
                    sourceRootComponents: sourceRootComponents
                )

                if shouldExclude(relativePath: relativePath, values: resourceValues) {
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

                guard let mediaType = detectMediaType(for: resolvedURL) else {
                    continue
                }

                guard let fileSize = resourceValues.fileSize else {
                    errors.append(ScanErrorRecord(path: url.path, message: "Unable to read file size"))
                    continue
                }

                let mtime = resourceValues.contentModificationDate ?? Date(timeIntervalSince1970: 0)
                let creationDate = resourceValues.creationDate
                let photoMetadata = mediaType == .photo
                    ? resolvedPhotoMetadata(from: resolvedURL, fallbackMtime: mtime)
                    : nil
                let videoMetadata: VideoMetadata?
                if mediaType == .video {
                    switch mode {
                    case .preview:
                        videoMetadata = previewVideoMetadataExtractor.extract(from: resolvedURL, fallbackMtime: mtime)
                    case .deep:
                        videoMetadata = videoMetadataExtractor.extract(from: resolvedURL, fallbackMtime: mtime)
                    }
                } else {
                    videoMetadata = nil
                }
                let sidecars = try discoverSidecars(
                    for: resolvedURL,
                    canonicalSourceRootURL: canonicalSourceRootURL,
                    sourceRootComponents: sourceRootComponents,
                    siblingURLCache: &siblingURLCache
                )

                let candidate = MediaCandidate(
                    absolutePath: resolvedURL.path,
                    relativePath: relativePath,
                    mediaType: mediaType,
                    sizeBytes: Int64(fileSize),
                    mtime: mtime,
                    creationDate: creationDate,
                    photoMetadata: photoMetadata,
                    videoMetadata: videoMetadata,
                    sidecars: sidecars
                )
                candidates.append(candidate)
                let cameraLabel = cameraLabeler.infer(for: candidate).cameraLabel
                cameraLabelCounts[cameraLabel, default: 0] += 1

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
                        photoCount: photoCount,
                        videoCount: videoCount,
                        totalBytes: photoBytes + videoBytes,
                        cameraLabelCounts: cameraLabelCounts
                    ))
                }
            } catch let sourceError as SourceScannerError {
                throw sourceError
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

    private func discoverSidecars(
        for mediaURL: URL,
        canonicalSourceRootURL: URL,
        sourceRootComponents: [String],
        siblingURLCache: inout [String: [URL]]
    ) throws -> [MediaSidecar] {
        let directoryPath = mediaURL.deletingLastPathComponent().standardizedFileURL.path
        let siblingURLs: [URL]
        if let cached = siblingURLCache[directoryPath] {
            siblingURLs = cached
        } else {
            siblingURLs = (try? fileManager.contentsOfDirectory(
                at: mediaURL.deletingLastPathComponent(),
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            siblingURLCache[directoryPath] = siblingURLs
        }

        let sidecarURLs = MediaSidecarSupport.discoverSidecarURLs(
            for: mediaURL,
            fileManager: fileManager,
            siblingURLs: siblingURLs
        )

        return try sidecarURLs.compactMap { sidecarURL in
            let standardized = sidecarURL.standardizedFileURL
            let values = try standardized.resourceValues(forKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .isReadableKey,
                .fileSizeKey,
                .contentModificationDateKey,
                .creationDateKey,
            ])

            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                return nil
            }
            guard values.isReadable != false else {
                return nil
            }
            guard let fileSize = values.fileSize else {
                return nil
            }

            let relativePath = try normalizeRelativePath(
                url: standardized,
                canonicalSourceRootURL: canonicalSourceRootURL,
                sourceRootComponents: sourceRootComponents
            )

            return MediaSidecar(
                absolutePath: standardized.path,
                relativePath: relativePath,
                sizeBytes: Int64(fileSize),
                mtime: values.contentModificationDate ?? Date(timeIntervalSince1970: 0),
                creationDate: values.creationDate,
                fileExtension: standardized.pathExtension.lowercased()
            )
        }
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
            cameraSerial: extracted.cameraSerial
        )
    }

    private func normalizeRelativePath(
        url: URL,
        canonicalSourceRootURL: URL,
        sourceRootComponents: [String]
    ) throws -> String {
        let candidateComponents = url.pathComponents
        guard candidateComponents.starts(with: sourceRootComponents) else {
            throw SourceScannerError.sourceBoundaryViolation(
                path: url.path,
                sourceRoot: canonicalSourceRootURL.path
            )
        }

        let relativeComponents = candidateComponents.dropFirst(sourceRootComponents.count)
        return relativeComponents.joined(separator: "/")
    }

    private func shouldExclude(relativePath: String, values: URLResourceValues) -> Bool {
        if values.isHidden == true {
            return true
        }

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
        photoCount: Int,
        videoCount: Int,
        totalBytes: Int64,
        cameraLabelCounts: [String: Int]
    ) -> ScanProgressSnapshot {
        ScanProgressSnapshot(
            itemCount: photoCount + videoCount,
            photoCount: photoCount,
            videoCount: videoCount,
            totalBytes: totalBytes,
            cameraAssessment: makeCameraAssessment(
                cameraLabelCounts: cameraLabelCounts,
                totalCandidates: photoCount + videoCount
            )
        )
    }

    private func makeCameraAssessment(
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
