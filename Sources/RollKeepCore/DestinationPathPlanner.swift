import Foundation

public struct DestinationPathPlanner: Sendable {
    private let mediaTypeDirectoryResolver: MediaTypeDirectoryResolver
    private let pathScheme: ImportPathScheme
    private let photoCompressionClassifier: PhotoCompressionClassifier

    public init(
        fileManager: FileManager = .default,
        pathScheme: ImportPathScheme = .default,
        photoCompressionClassifier: PhotoCompressionClassifier = PhotoCompressionClassifier()
    ) {
        mediaTypeDirectoryResolver = MediaTypeDirectoryResolver(fileManager: fileManager)
        self.pathScheme = pathScheme
        self.photoCompressionClassifier = photoCompressionClassifier
    }

    public struct SourceFile: Sendable {
        public let candidate: MediaCandidate
        public let cameraLabel: String
        public let sourceHash: String?
        public let photoCompressionBucketOverride: PhotoCompressionBucket?

        public init(
            candidate: MediaCandidate,
            cameraLabel: String,
            sourceHash: String? = nil,
            photoCompressionBucketOverride: PhotoCompressionBucket? = nil
        ) {
            self.candidate = candidate
            self.cameraLabel = cameraLabel
            self.sourceHash = sourceHash
            self.photoCompressionBucketOverride = photoCompressionBucketOverride
        }
    }

    public enum Disposition: String, Sendable {
        case stageAndCommit = "stage_and_commit"
        case duplicateNotCopied = "duplicate_not_copied"
    }

    public struct PlannedFile: Sendable {
        public let candidate: MediaCandidate
        public let cameraLabel: String
        public let sourceHash: String?
        public let finalPath: String
        public let stagingPath: String?
        public let disposition: Disposition
        public let collisionResolved: Bool
        public let collisionSuffix: Int?
        public let duplicateOfPath: String?
        public let photoCompressionBucket: PhotoCompressionBucket?
    }

    public struct Plan: Sendable {
        public let files: [PlannedFile]
        public let directoriesToCreate: [String]

        public var duplicatesSkipped: Int {
            files.filter { $0.disposition == .duplicateNotCopied }.count
        }

        public var conflictsRenamed: Int {
            files.filter(\.collisionResolved).count
        }
    }

    public func plan(
        destRoot: URL,
        sessionID: String,
        files: [SourceFile],
        existingFinalFiles: [String: String?] = [:]
    ) -> Plan {
        var occupiedByHash: [String: String?] = [:]
        var occupiedPathByLookupKey: [String: String] = [:]
        for (path, hash) in existingFinalFiles {
            let normalizedPath = normalizePath(path)
            let lookupKey = pathLookupKey(normalizedPath)
            if occupiedPathByLookupKey[lookupKey] == nil {
                occupiedByHash[normalizedPath] = hash
                occupiedPathByLookupKey[lookupKey] = normalizedPath
            }
        }
        var planned: [PlannedFile] = []
        var directories: Set<String> = []
        var mediaTypeFolderCache: [String: String] = [:]

        for file in files {
            let captureDate = captureDate(for: file.candidate)
            let cameraLabel = sanitizeCameraLabel(file.cameraLabel)
            let filename = sourceFilename(for: file.candidate)
            let photoCompressionBucket = resolvedPhotoCompressionBucket(for: file)
            let isAudio = file.candidate.mediaType == .audio

            let finalParentURL: URL
            let mediaTypeFolder: String?
            if isAudio {
                finalParentURL = audioParentDirectory(destRoot: destRoot, captureDate: captureDate)
                mediaTypeFolder = nil
            } else {
                let libraryParentURL = libraryMediaParentDirectory(
                    destRoot: destRoot,
                    captureDate: captureDate,
                    cameraLabel: cameraLabel
                )
                finalParentURL = libraryParentURL
                // The resolved media-type folder for a given (parent, mediaType)
                // is invariant across files within one plan() call: the
                // filesystem isn't mutated here, and once a bucket's folder name
                // is established (canonical, or an existing on-disk casing) every
                // later file resolves to the same name. Memoize it to avoid a
                // per-file directory listing plus an O(N) knownFilePaths scan
                // (O(N^2) over a large card import).
                let mediaTypeFolderKey = "\(file.candidate.mediaType.rawValue)\u{0}\(libraryParentURL.path)"
                if let cachedFolder = mediaTypeFolderCache[mediaTypeFolderKey] {
                    mediaTypeFolder = cachedFolder
                } else {
                    let resolvedFolder = mediaTypeDirectoryResolver.directoryName(
                        for: file.candidate.mediaType,
                        parentDirectory: libraryParentURL,
                        knownFilePaths: Array(occupiedByHash.keys)
                    )
                    mediaTypeFolderCache[mediaTypeFolderKey] = resolvedFolder
                    mediaTypeFolder = resolvedFolder
                }
            }
            let compressionDirectoryName = pathScheme.compressionDirectoryName(
                mediaType: file.candidate.mediaType,
                photoCompressionBucket: photoCompressionBucket
            )

            var finalDirURL = finalParentURL
            if let mediaTypeFolder {
                finalDirURL = finalDirURL.appendingPathComponent(mediaTypeFolder, isDirectory: true)
            }
            if let compressionDirectoryName {
                finalDirURL = finalDirURL.appendingPathComponent(compressionDirectoryName, isDirectory: true)
            }
            let baseFinalPath = finalDirURL.appendingPathComponent(filename, isDirectory: false).path
            let resolved = resolveFinalPath(
                basePath: baseFinalPath,
                sourceHash: file.sourceHash,
                occupiedByHash: occupiedByHash,
                occupiedPathByLookupKey: occupiedPathByLookupKey
            )

            switch resolved.kind {
            case .duplicate:
                planned.append(PlannedFile(
                    candidate: file.candidate,
                    cameraLabel: cameraLabel,
                    sourceHash: file.sourceHash,
                    finalPath: resolved.path,
                    stagingPath: nil,
                    disposition: .duplicateNotCopied,
                    collisionResolved: false,
                    collisionSuffix: nil,
                    duplicateOfPath: resolved.path,
                    photoCompressionBucket: photoCompressionBucket
                ))
            case .commit:
                var stagingDirURL = isAudio
                    ? audioStagingParentDirectory(destRoot: destRoot, sessionID: sessionID, captureDate: captureDate)
                    : stagingMediaParentDirectory(
                        destRoot: destRoot,
                        sessionID: sessionID,
                        captureDate: captureDate,
                        cameraLabel: cameraLabel
                    )
                if let mediaTypeFolder {
                    stagingDirURL = stagingDirURL.appendingPathComponent(mediaTypeFolder, isDirectory: true)
                }
                if let compressionDirectoryName {
                    stagingDirURL = stagingDirURL.appendingPathComponent(compressionDirectoryName, isDirectory: true)
                }
                let stagingPath = stagingDirURL.appendingPathComponent(lastPathComponent(of: resolved.path), isDirectory: false).path

                occupiedByHash[normalizePath(resolved.path)] = file.sourceHash
                occupiedPathByLookupKey[pathLookupKey(resolved.path)] = normalizePath(resolved.path)
                directories.insert(normalizePath(finalDirURL.path))
                directories.insert(normalizePath(stagingDirURL.path))

                planned.append(PlannedFile(
                    candidate: file.candidate,
                    cameraLabel: cameraLabel,
                    sourceHash: file.sourceHash,
                    finalPath: resolved.path,
                    stagingPath: stagingPath,
                    disposition: .stageAndCommit,
                    collisionResolved: resolved.collisionSuffix != nil,
                    collisionSuffix: resolved.collisionSuffix,
                    duplicateOfPath: nil,
                    photoCompressionBucket: photoCompressionBucket
                ))
            }
        }

        return Plan(
            files: planned,
            directoriesToCreate: directories.sorted()
        )
    }

    private enum ResolveKind {
        case commit
        case duplicate
    }

    private struct ResolvedFinalPath {
        let kind: ResolveKind
        let path: String
        let collisionSuffix: Int?
    }

    private func resolveFinalPath(
        basePath: String,
        sourceHash: String?,
        occupiedByHash: [String: String?],
        occupiedPathByLookupKey: [String: String]
    ) -> ResolvedFinalPath {
        let normalizedBasePath = normalizePath(basePath)
        let normalizedBaseLookupKey = pathLookupKey(normalizedBasePath)

        if let existingPath = occupiedPathByLookupKey[normalizedBaseLookupKey] {
            let existingHash = occupiedByHash[existingPath] ?? nil
            if isDuplicate(sourceHash: sourceHash, existingHash: existingHash) {
                return ResolvedFinalPath(kind: .duplicate, path: existingPath, collisionSuffix: nil)
            }

            var suffix = 1
            while true {
                let candidatePath = normalizePath(pathByAppendingCollisionSuffix(basePath: normalizedBasePath, suffix: suffix))
                let candidateLookupKey = pathLookupKey(candidatePath)
                if let occupiedCandidatePath = occupiedPathByLookupKey[candidateLookupKey] {
                    let candidateHash = occupiedByHash[occupiedCandidatePath] ?? nil
                    if isDuplicate(sourceHash: sourceHash, existingHash: candidateHash) {
                        return ResolvedFinalPath(kind: .duplicate, path: occupiedCandidatePath, collisionSuffix: nil)
                    }
                    suffix += 1
                    continue
                }

                return ResolvedFinalPath(kind: .commit, path: candidatePath, collisionSuffix: suffix)
            }
        }

        return ResolvedFinalPath(kind: .commit, path: normalizedBasePath, collisionSuffix: nil)
    }

    private func libraryMediaParentDirectory(
        destRoot: URL,
        captureDate: Date?,
        cameraLabel: String
    ) -> URL {
        var result = destRoot
        for component in pathScheme.pathPrefixComponents(captureDate: captureDate, cameraLabel: cameraLabel) {
            result = result.appendingPathComponent(component, isDirectory: true)
        }
        return result
    }

    private func stagingMediaParentDirectory(
        destRoot: URL,
        sessionID: String,
        captureDate: Date?,
        cameraLabel: String
    ) -> URL {
        var result = destRoot
            .appendingPathComponent("_ingest_staging", isDirectory: true)
            .appendingPathComponent(sessionID, isDirectory: true)
        for component in pathScheme.pathPrefixComponents(captureDate: captureDate, cameraLabel: cameraLabel) {
            result = result.appendingPathComponent(component, isDirectory: true)
        }
        return result
    }

    private func audioParentDirectory(destRoot: URL, captureDate: Date?) -> URL {
        var result = destRoot
        for component in pathScheme.audioPathPrefixComponents(captureDate: captureDate) {
            result = result.appendingPathComponent(component, isDirectory: true)
        }
        return result
    }

    private func audioStagingParentDirectory(destRoot: URL, sessionID: String, captureDate: Date?) -> URL {
        var result = destRoot
            .appendingPathComponent("_ingest_staging", isDirectory: true)
            .appendingPathComponent(sessionID, isDirectory: true)
        for component in pathScheme.audioPathPrefixComponents(captureDate: captureDate) {
            result = result.appendingPathComponent(component, isDirectory: true)
        }
        return result
    }

    private func captureDate(for candidate: MediaCandidate) -> Date? {
        switch candidate.mediaType {
        case .photo:
            return candidate.photoMetadata?.captureDateTime
        case .video:
            return candidate.videoMetadata?.captureDateTime
        case .audio:
            return candidate.audioMetadata?.captureDateTime
        }
    }

    private func sourceFilename(for candidate: MediaCandidate) -> String {
        let filename = lastPathComponent(of: candidate.relativePath)
        return filename.isEmpty ? "unknown-file" : filename
    }

    private func resolvedPhotoCompressionBucket(for file: SourceFile) -> PhotoCompressionBucket? {
        guard pathScheme.splitPhotoCompression, file.candidate.mediaType == .photo else {
            return nil
        }

        if let override = file.photoCompressionBucketOverride {
            return override
        }

        return photoCompressionClassifier.bucket(forRelativePath: file.candidate.relativePath)
    }

    private func pathByAppendingCollisionSuffix(basePath: String, suffix: Int) -> String {
        let filename = lastPathComponent(of: basePath)
        let ext = (filename as NSString).pathExtension
        let stem = (filename as NSString).deletingPathExtension
        let suffixedName: String
        if ext.isEmpty {
            suffixedName = "\(stem)-\(suffix)"
        } else {
            suffixedName = "\(stem)-\(suffix).\(ext)"
        }

        return URL(fileURLWithPath: basePath, isDirectory: false)
            .deletingLastPathComponent()
            .appendingPathComponent(suffixedName, isDirectory: false)
            .path
    }

    private func isDuplicate(sourceHash: String?, existingHash: String?) -> Bool {
        guard let sourceHash, let existingHash else {
            return false
        }
        return sourceHash == existingHash
    }

    private func sanitizeCameraLabel(_ label: String) -> String {
        var result = ""
        var previousWasSeparator = false

        for scalar in label.lowercased().unicodeScalars {
            guard scalar.isASCII else {
                continue
            }

            if CharacterSet.alphanumerics.contains(scalar) {
                result.unicodeScalars.append(scalar)
                previousWasSeparator = false
                continue
            }

            if scalar == "-" {
                if !previousWasSeparator, !result.isEmpty {
                    result.append("-")
                    previousWasSeparator = true
                }
                continue
            }

            if !previousWasSeparator, !result.isEmpty {
                result.append("-")
                previousWasSeparator = true
            }
        }

        let trimmed = result.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "unknown-camera" : trimmed
    }

    private func lastPathComponent(of path: String) -> String {
        (path as NSString).lastPathComponent
    }

    private func normalizePath(_ path: String) -> String {
        URL(fileURLWithPath: path, isDirectory: false).standardizedFileURL.path
    }

    private func pathLookupKey(_ path: String) -> String {
        normalizePath(path).folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
}
