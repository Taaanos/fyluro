import Foundation

enum MediaType: String {
    case photo
    case video
}

enum PhotoCaptureDateSource: String {
    case dateTimeOriginal = "DateTimeOriginal"
    case createDate = "CreateDate"
    case missing
}

struct PhotoMetadata {
    let captureDateTime: Date?
    let captureDateSource: PhotoCaptureDateSource
    let cameraMake: String?
    let cameraModel: String?
    let cameraSerial: String?

    var planBucket: String {
        captureDateTime == nil ? "_unsorted" : "dated"
    }
}

protocol PhotoMetadataExtracting {
    func extract(from fileURL: URL) -> PhotoMetadata
}

struct MediaCandidate {
    let absolutePath: String
    let relativePath: String
    let mediaType: MediaType
    let sizeBytes: Int64
    let mtime: Date
    let photoMetadata: PhotoMetadata?
}

struct ScanErrorRecord {
    let path: String
    let message: String
}

struct ScanSummary {
    let candidates: [MediaCandidate]
    let photoCount: Int
    let videoCount: Int
    let photoBytes: Int64
    let videoBytes: Int64
    let filesInTypicalLocations: Int
    let filesOutsideTypicalLocations: Int
    let errors: [ScanErrorRecord]
}

enum SourceScannerError: Error {
    case unreadableSourceRoot(String)
}

struct SourceScanner {
    private let fileManager: FileManager
    private let photoMetadataExtractor: PhotoMetadataExtracting

    init(
        fileManager: FileManager = .default,
        photoMetadataExtractor: PhotoMetadataExtracting = ImageIOPhotoMetadataExtractor()
    ) {
        self.fileManager = fileManager
        self.photoMetadataExtractor = photoMetadataExtractor
    }

    func scan(sourceRoot: URL) throws -> ScanSummary {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: sourceRoot.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              fileManager.isReadableFile(atPath: sourceRoot.path)
        else {
            throw SourceScannerError.unreadableSourceRoot(sourceRoot.path)
        }

        var candidates: [MediaCandidate] = []
        var errors: [ScanErrorRecord] = []

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

                candidates.append(MediaCandidate(
                    absolutePath: url.path,
                    relativePath: relativePath,
                    mediaType: mediaType,
                    sizeBytes: Int64(fileSize),
                    mtime: mtime,
                    photoMetadata: photoMetadata
                ))
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

        var photoCount = 0
        var videoCount = 0
        var photoBytes: Int64 = 0
        var videoBytes: Int64 = 0
        var filesInTypicalLocations = 0

        for candidate in candidates {
            switch candidate.mediaType {
            case .photo:
                photoCount += 1
                photoBytes += candidate.sizeBytes
            case .video:
                videoCount += 1
                videoBytes += candidate.sizeBytes
            }

            if isInTypicalMediaLocation(relativePath: candidate.relativePath) {
                filesInTypicalLocations += 1
            }
        }

        return ScanSummary(
            candidates: candidates,
            photoCount: photoCount,
            videoCount: videoCount,
            photoBytes: photoBytes,
            videoBytes: videoBytes,
            filesInTypicalLocations: filesInTypicalLocations,
            filesOutsideTypicalLocations: candidates.count - filesInTypicalLocations,
            errors: errors
        )
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
}
