import CommonCrypto
import Foundation
import RollKeepCore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

struct StagingCommitEngine {
    struct Configuration {
        let chunkSize: Int
        let maxCollisionSuffix: Int

        init(chunkSize: Int = 1_048_576, maxCollisionSuffix: Int = 100_000) {
            self.chunkSize = chunkSize
            self.maxCollisionSuffix = maxCollisionSuffix
        }
    }

    struct FileJob {
        let relativePath: String
        let sourcePath: String
        let stagingPath: String
        let plannedFinalPath: String
        let plannedCollisionSuffix: Int?
        let bytesCopied: Int64
        let sourceHashSHA256: String
        let sourceModificationDate: Date
        let sourceCreationDate: Date?

        init(
            relativePath: String,
            sourcePath: String,
            stagingPath: String,
            plannedFinalPath: String,
            plannedCollisionSuffix: Int? = nil,
            bytesCopied: Int64,
            sourceHashSHA256: String,
            sourceModificationDate: Date = Date(timeIntervalSince1970: 0),
            sourceCreationDate: Date? = nil
        ) {
            self.relativePath = relativePath
            self.sourcePath = sourcePath
            self.stagingPath = stagingPath
            self.plannedFinalPath = plannedFinalPath
            self.plannedCollisionSuffix = plannedCollisionSuffix
            self.bytesCopied = bytesCopied
            self.sourceHashSHA256 = sourceHashSHA256
            self.sourceModificationDate = sourceModificationDate
            self.sourceCreationDate = sourceCreationDate
        }
    }

    enum Disposition: String {
        case committed = "committed"
        case duplicateNotCopied = "duplicate_not_copied"
    }

    enum MoveStrategy: String {
        case rename = "rename"
        case copyThenRemove = "copy_then_remove"
        case none = "none"
    }

    struct FileResult {
        let relativePath: String
        let sourcePath: String
        let stagingPath: String
        let plannedFinalPath: String
        let finalPath: String
        let bytesCopied: Int64
        let sourceHashSHA256: String
        let disposition: Disposition
        let collisionResolved: Bool
        let collisionSuffix: Int?
        let moveStrategy: MoveStrategy
    }

    struct FileFailure {
        let relativePath: String
        let sourcePath: String
        let stagingPath: String
        let plannedFinalPath: String
        let attemptedFinalPath: String?
        let phase: IngestPhase
        let message: String
    }

    enum EngineError: Error {
        case invalidConfiguration(String)
        case runFailed(partialResults: [FileResult], remaining: [FileJob], failure: FileFailure)
    }

    private let destinationRoot: URL
    private let configuration: Configuration
    private let fileManager: FileManager
    private let mediaTypeDirectoryResolver: MediaTypeDirectoryResolver
    private let onBeforeMove: ((FileJob, String) throws -> Void)?
    private let onCommitted: ((FileResult) -> Void)?

    init(
        destinationRoot: URL,
        configuration: Configuration = Configuration(),
        fileManager: FileManager = .default,
        onBeforeMove: ((FileJob, String) throws -> Void)? = nil,
        onCommitted: ((FileResult) -> Void)? = nil
    ) {
        self.destinationRoot = destinationRoot
        self.configuration = configuration
        self.fileManager = fileManager
        self.mediaTypeDirectoryResolver = MediaTypeDirectoryResolver(fileManager: fileManager)
        self.onBeforeMove = onBeforeMove
        self.onCommitted = onCommitted
    }

    func commit(files: [FileJob]) throws -> [FileResult] {
        guard configuration.chunkSize > 0 else {
            throw EngineError.invalidConfiguration("chunkSize must be greater than 0")
        }
        guard configuration.maxCollisionSuffix > 0 else {
            throw EngineError.invalidConfiguration("maxCollisionSuffix must be greater than 0")
        }
        guard !files.isEmpty else {
            return []
        }

        var results: [FileResult] = []
        results.reserveCapacity(files.count)
        // The resolved media-type directory for a given planned parent is
        // invariant across one commit run: resolution only rewrites the
        // <Photos|Videos> component, and the loop then creates exactly the name
        // it resolved, so a later listing would report that same name back.
        // Memoize it to avoid re-listing the destination directory per file.
        var resolvedParentDirectoryCache: [String: String] = [:]

        for (index, file) in files.enumerated() {
            do {
                let result = try commitSingle(file, resolvedParentDirectoryCache: &resolvedParentDirectoryCache)
                results.append(result)
                onCommitted?(result)
            } catch let singleError as SingleFileError {
                let remaining = Array(files.dropFirst(index + 1))
                throw EngineError.runFailed(
                    partialResults: results,
                    remaining: remaining,
                    failure: singleError.failure
                )
            }
        }

        return results
    }

    private enum CommitResolution {
        case commit(finalPath: String, collisionSuffix: Int?)
        case duplicate(finalPath: String, collisionSuffix: Int?)
    }

    private func commitSingle(
        _ job: FileJob,
        resolvedParentDirectoryCache: inout [String: String]
    ) throws -> FileResult {
        func makeFailure(message: String, attemptedFinalPath: String? = nil) -> FileFailure {
            FileFailure(
                relativePath: job.relativePath,
                sourcePath: job.sourcePath,
                stagingPath: job.stagingPath,
                plannedFinalPath: job.plannedFinalPath,
                attemptedFinalPath: attemptedFinalPath,
                phase: .commit,
                message: message
            )
        }

        guard fileManager.fileExists(atPath: job.stagingPath) else {
            throw SingleFileError(failure: makeFailure(message: "Staging file does not exist"))
        }

        var collisionAttempts = 0
        while true {
            let resolution: CommitResolution
            do {
                resolution = try resolveCommitPath(
                    for: job,
                    resolvedParentDirectoryCache: &resolvedParentDirectoryCache
                )
            } catch {
                throw SingleFileError(failure: makeFailure(
                    message: "Failed to resolve final path: \(error.localizedDescription)"
                ))
            }

            switch resolution {
            case .duplicate(let finalPath, let collisionSuffix):
                return FileResult(
                    relativePath: job.relativePath,
                    sourcePath: job.sourcePath,
                    stagingPath: job.stagingPath,
                    plannedFinalPath: job.plannedFinalPath,
                    finalPath: finalPath,
                    bytesCopied: job.bytesCopied,
                    sourceHashSHA256: job.sourceHashSHA256,
                    disposition: .duplicateNotCopied,
                    collisionResolved: collisionSuffix != nil,
                    collisionSuffix: collisionSuffix,
                    moveStrategy: .none
                )
            case .commit(let finalPath, let collisionSuffix):
                do {
                    let parentDir = try openOrCreateSafeDestinationDirectory(for: finalPath)
                    defer { close(parentDir.directoryFD) }

                    try onBeforeMove?(job, finalPath)
                    let moveStrategy = try moveStagingToFinal(
                        stagingPath: job.stagingPath,
                        finalPath: finalPath,
                        destinationDirFD: parentDir.directoryFD,
                        destinationFilename: parentDir.filename
                    )
                    try applySourceDates(
                        finalPath: finalPath,
                        sourceModificationDate: job.sourceModificationDate,
                        sourceCreationDate: job.sourceCreationDate
                    )
                    return FileResult(
                        relativePath: job.relativePath,
                        sourcePath: job.sourcePath,
                        stagingPath: job.stagingPath,
                        plannedFinalPath: job.plannedFinalPath,
                        finalPath: finalPath,
                        bytesCopied: job.bytesCopied,
                        sourceHashSHA256: job.sourceHashSHA256,
                        disposition: .committed,
                        collisionResolved: collisionSuffix != nil,
                        collisionSuffix: collisionSuffix,
                        moveStrategy: moveStrategy
                    )
                } catch DestinationExistsRaceError.destinationNowExists {
                    collisionAttempts += 1
                    if collisionAttempts > configuration.maxCollisionSuffix {
                        throw SingleFileError(failure: makeFailure(
                            message: "Unable to resolve deterministic collision suffix within limit",
                            attemptedFinalPath: finalPath
                        ))
                    }
                    continue
                } catch {
                    throw SingleFileError(failure: makeFailure(
                        message: error.localizedDescription,
                        attemptedFinalPath: finalPath
                    ))
                }
            }
        }
    }

    private func applySourceDates(
        finalPath: String,
        sourceModificationDate: Date,
        sourceCreationDate: Date?
    ) throws {
        do {
            try fileManager.setAttributes([.modificationDate: sourceModificationDate], ofItemAtPath: finalPath)
        } catch {
            throw CommitEngineError.moveFailed("Failed to preserve source modification date: \(error.localizedDescription)")
        }

        let creationDateToApply = sourceCreationDate ?? sourceModificationDate
        // Not all destination filesystems allow setting creation date; keep ingest successful when unsupported.
        try? fileManager.setAttributes([.creationDate: creationDateToApply], ofItemAtPath: finalPath)
    }

    private func resolveCommitPath(
        for job: FileJob,
        resolvedParentDirectoryCache: inout [String: String]
    ) throws -> CommitResolution {
        try validateExistingDestinationPath(job.plannedFinalPath)

        let untruncatedBasePath = resolveUntruncatedBasePath(
            for: job,
            resolvedParentDirectoryCache: &resolvedParentDirectoryCache
        )

        if job.plannedCollisionSuffix != nil {
            try validateExistingDestinationPath(untruncatedBasePath)
            if fileManager.fileExists(atPath: untruncatedBasePath),
               try isDuplicate(existingPath: untruncatedBasePath, expectedBytes: job.bytesCopied, sourceHash: job.sourceHashSHA256) {
                return .duplicate(finalPath: untruncatedBasePath, collisionSuffix: nil)
            }
        }

        let basePath = resolveMediaTypeBasePath(
            for: job.plannedFinalPath,
            cache: &resolvedParentDirectoryCache
        )
        try validateExistingDestinationPath(basePath)
        if !fileManager.fileExists(atPath: basePath) {
            return .commit(finalPath: basePath, collisionSuffix: nil)
        }

        if try isDuplicate(existingPath: basePath, expectedBytes: job.bytesCopied, sourceHash: job.sourceHashSHA256) {
            return .duplicate(finalPath: basePath, collisionSuffix: nil)
        }

        let suffixBasePath = job.plannedCollisionSuffix != nil ? untruncatedBasePath : basePath
        var suffix = (job.plannedCollisionSuffix ?? 0) + 1
        while suffix <= configuration.maxCollisionSuffix {
            let candidate = normalizePath(pathByAppendingCollisionSuffix(basePath: suffixBasePath, suffix: suffix))
            try validateExistingDestinationPath(candidate)
            if !fileManager.fileExists(atPath: candidate) {
                return .commit(finalPath: candidate, collisionSuffix: suffix)
            }

            if try isDuplicate(existingPath: candidate, expectedBytes: job.bytesCopied, sourceHash: job.sourceHashSHA256) {
                return .duplicate(finalPath: candidate, collisionSuffix: suffix)
            }

            suffix += 1
        }

        throw CommitEngineError.collisionLimitExceeded
    }

    private func resolveUntruncatedBasePath(
        for job: FileJob,
        resolvedParentDirectoryCache: inout [String: String]
    ) -> String {
        let sourceFilename = (job.relativePath as NSString).lastPathComponent
        let rawBasePath: String
        if job.plannedCollisionSuffix != nil, !sourceFilename.isEmpty {
            rawBasePath = URL(fileURLWithPath: job.plannedFinalPath, isDirectory: false)
                .deletingLastPathComponent()
                .appendingPathComponent(sourceFilename, isDirectory: false)
                .path
        } else {
            rawBasePath = job.plannedFinalPath
        }
        return resolveMediaTypeBasePath(for: rawBasePath, cache: &resolvedParentDirectoryCache)
    }

    // Resolves the media-type directory casing for a planned final path,
    // memoizing per planned parent directory. `resolvePath` only rewrites the
    // <Photos|Videos> directory component and appends the filename unchanged, so
    // caching `parentDirectory -> resolvedParentDirectory` reproduces its output
    // exactly while listing each destination bucket at most once per run.
    private func resolveMediaTypeBasePath(
        for plannedFinalPath: String,
        cache: inout [String: String]
    ) -> String {
        let normalizedPlannedPath = normalizePath(plannedFinalPath)
        // Non-absolute paths are returned unchanged by `resolvePath`; skip the
        // cache and let it handle them so behavior stays identical.
        guard normalizedPlannedPath.hasPrefix("/") else {
            return mediaTypeDirectoryResolver.resolvePath(plannedFinalPath)
        }

        let plannedURL = URL(fileURLWithPath: normalizedPlannedPath, isDirectory: false)
        let filename = plannedURL.lastPathComponent
        let parentDirectoryKey = plannedURL.deletingLastPathComponent().path

        let resolvedParentDirectory: String
        if let cached = cache[parentDirectoryKey] {
            resolvedParentDirectory = cached
        } else {
            let resolvedPath = mediaTypeDirectoryResolver.resolvePath(plannedFinalPath)
            resolvedParentDirectory = URL(fileURLWithPath: resolvedPath, isDirectory: false)
                .deletingLastPathComponent()
                .path
            cache[parentDirectoryKey] = resolvedParentDirectory
        }

        return URL(fileURLWithPath: resolvedParentDirectory, isDirectory: true)
            .appendingPathComponent(filename, isDirectory: false)
            .path
    }

    private func moveStagingToFinal(
        stagingPath: String,
        finalPath: String,
        destinationDirFD: Int32,
        destinationFilename: String
    ) throws -> MoveStrategy {
        if type(of: fileManager) != FileManager.self {
            do {
                try fileManager.moveItem(atPath: stagingPath, toPath: finalPath)
                return .rename
            } catch {
                if isDestinationExistsError(error) {
                    throw DestinationExistsRaceError.destinationNowExists
                }
                if isCrossVolumeMoveError(error) {
                    do {
                        try fileManager.copyItem(atPath: stagingPath, toPath: finalPath)
                        try fileManager.removeItem(atPath: stagingPath)
                        return .copyThenRemove
                    } catch {
                        throw CommitEngineError.crossVolumeFallbackFailed(
                            "Cross-volume copy/remove fallback failed: \(error.localizedDescription)"
                        )
                    }
                }

                throw CommitEngineError.moveFailed("Failed to move staged file to final path: \(error.localizedDescription)")
            }
        }

        #if canImport(Darwin)
        if renameatx_np(AT_FDCWD, stagingPath, destinationDirFD, destinationFilename, UInt32(RENAME_EXCL)) == 0 {
            return .rename
        }
        let renameErr = errno
        if renameErr == EEXIST {
            throw DestinationExistsRaceError.destinationNowExists
        }
        if renameErr == EXDEV {
            try copyAcrossVolumesNoFollow(
                stagingPath: stagingPath,
                destinationDirFD: destinationDirFD,
                destinationFilename: destinationFilename
            )
            return .copyThenRemove
        }
        if renameErr == ENOTSUP || renameErr == EINVAL {
            try checkDestinationEntryAbsentOrFail(in: destinationDirFD, filename: destinationFilename)
            if renameat(AT_FDCWD, stagingPath, destinationDirFD, destinationFilename) == 0 {
                return .rename
            }
            let fallbackErr = errno
            if fallbackErr == EEXIST {
                throw DestinationExistsRaceError.destinationNowExists
            }
            if fallbackErr == EXDEV {
                try copyAcrossVolumesNoFollow(
                    stagingPath: stagingPath,
                    destinationDirFD: destinationDirFD,
                    destinationFilename: destinationFilename
                )
                return .copyThenRemove
            }
            throw CommitEngineError.moveFailed(
                "Failed to move staged file to final path: \(String(cString: strerror(fallbackErr)))"
            )
        }
        throw CommitEngineError.moveFailed(
            "Failed to move staged file to final path: \(String(cString: strerror(renameErr)))"
        )
        #else
        try checkDestinationEntryAbsentOrFail(in: destinationDirFD, filename: destinationFilename)
        if renameat(AT_FDCWD, stagingPath, destinationDirFD, destinationFilename) == 0 {
            return .rename
        }
        let renameErr = errno
        if renameErr == EEXIST {
            throw DestinationExistsRaceError.destinationNowExists
        }
        if renameErr == EXDEV {
            try copyAcrossVolumesNoFollow(
                stagingPath: stagingPath,
                destinationDirFD: destinationDirFD,
                destinationFilename: destinationFilename
            )
            return .copyThenRemove
        }
        throw CommitEngineError.moveFailed(
            "Failed to move staged file to final path: \(String(cString: strerror(renameErr)))"
        )
        #endif
    }

    private func copyAcrossVolumesNoFollow(
        stagingPath: String,
        destinationDirFD: Int32,
        destinationFilename: String
    ) throws {
        let sourceFD = open(stagingPath, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard sourceFD >= 0 else {
            throw CommitEngineError.crossVolumeFallbackFailed(
                "Cross-volume copy/remove fallback failed opening staging file: \(lastErrnoMessage())"
            )
        }
        defer { close(sourceFD) }

        var sourceStat = stat()
        guard fstat(sourceFD, &sourceStat) == 0, (sourceStat.st_mode & S_IFMT) == S_IFREG else {
            throw CommitEngineError.crossVolumeFallbackFailed(
                "Cross-volume copy/remove fallback failed: staging path is not a regular file"
            )
        }
        clearNonBlockingFlag(on: sourceFD)

        let destFD = openat(
            destinationDirFD,
            destinationFilename,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW,
            0o644
        )
        guard destFD >= 0 else {
            if errno == EEXIST {
                throw DestinationExistsRaceError.destinationNowExists
            }
            if isSymbolicLink(destinationFilename, in: destinationDirFD) || errno == ELOOP {
                throw CommitEngineError.symlinkNotAllowed("Destination path is a symbolic link: \(destinationFilename)")
            }
            throw CommitEngineError.crossVolumeFallbackFailed(
                "Cross-volume copy/remove fallback failed creating destination file: \(lastErrnoMessage())"
            )
        }

        var copySucceeded = false
        defer {
            close(destFD)
            if !copySucceeded {
                _ = unlinkat(destinationDirFD, destinationFilename, 0)
            }
        }

        var buffer = [UInt8](repeating: 0, count: configuration.chunkSize)
        while true {
            let bytesRead = buffer.withUnsafeMutableBytes { rawBuffer -> Int in
                guard let baseAddress = rawBuffer.baseAddress else { return -1 }
                return read(sourceFD, baseAddress, rawBuffer.count)
            }
            if bytesRead < 0 {
                throw CommitEngineError.crossVolumeFallbackFailed(
                    "Cross-volume copy/remove fallback read failed: \(lastErrnoMessage())"
                )
            }
            if bytesRead == 0 {
                break
            }

            var written = 0
            while written < bytesRead {
                let writeCount = buffer.withUnsafeBufferPointer { pointer -> Int in
                    guard let baseAddress = pointer.baseAddress else { return -1 }
                    return write(destFD, baseAddress.advanced(by: written), bytesRead - written)
                }
                if writeCount <= 0 {
                    throw CommitEngineError.crossVolumeFallbackFailed(
                        "Cross-volume copy/remove fallback write failed: \(lastErrnoMessage())"
                    )
                }
                written += writeCount
            }
        }

        copySucceeded = true
        guard unlink(stagingPath) == 0 else {
            throw CommitEngineError.crossVolumeFallbackFailed(
                "Cross-volume copy/remove fallback failed removing staging file: \(lastErrnoMessage())"
            )
        }
    }

    private func isDuplicate(existingPath: String, expectedBytes: Int64, sourceHash: String) throws -> Bool {
        guard let fd = try openExistingDestinationFileForHash(atPath: existingPath) else {
            return false
        }
        defer { close(fd) }

        var attributes = stat()
        guard fstat(fd, &attributes) == 0 else {
            return false
        }

        let existingSize = Int64(attributes.st_size)
        guard existingSize == expectedBytes else {
            return false
        }

        let existingHash = try hashFileSHA256(fd: fd)
        return existingHash == sourceHash
    }

    private func hashFileSHA256(fd: Int32) throws -> String {
        var hasher = CommitSHA256Hasher()
        var buffer = [UInt8](repeating: 0, count: configuration.chunkSize)

        while true {
            let bytesRead = buffer.withUnsafeMutableBytes { rawBuffer -> Int in
                guard let baseAddress = rawBuffer.baseAddress else { return -1 }
                return read(fd, baseAddress, rawBuffer.count)
            }
            if bytesRead < 0 {
                throw CommitEngineError.hashFailed("Read failed while hashing: \(lastErrnoMessage())")
            }
            if bytesRead == 0 {
                break
            }

            hasher.update(bytes: buffer, count: bytesRead)
        }

        return hasher.finalizeHex()
    }

    private func relativePathComponents(for targetPath: String) throws -> (directoryComponents: [String], filename: String) {
        let rootURL = destinationRoot.standardizedFileURL
        let targetURL = URL(fileURLWithPath: targetPath, isDirectory: false).standardizedFileURL
        let rootComponents = rootURL.pathComponents
        let targetComponents = targetURL.pathComponents

        guard targetComponents.count > rootComponents.count,
              Array(targetComponents.prefix(rootComponents.count)) == rootComponents else {
            throw CommitEngineError.outsideDestinationRoot(
                "Destination path \(targetPath) is outside library root \(rootURL.path)"
            )
        }

        let relative = Array(targetComponents.dropFirst(rootComponents.count))
        guard let filename = relative.last,
              !filename.isEmpty,
              filename != ".",
              filename != ".." else {
            throw CommitEngineError.outsideDestinationRoot(
                "Invalid destination filename in path \(targetPath)"
            )
        }

        let directoryComponents = Array(relative.dropLast())
        if directoryComponents.contains(".") || directoryComponents.contains("..") {
            throw CommitEngineError.outsideDestinationRoot(
                "Invalid relative directory traversal in path \(targetPath)"
            )
        }

        return (directoryComponents, filename)
    }

    private func openDestinationRootDirectory(createIfMissing: Bool) throws -> Int32? {
        let fd = open(destinationRoot.path, O_RDONLY | O_DIRECTORY)
        if fd >= 0 {
            return fd
        }

        if errno == ENOENT {
            if !createIfMissing {
                return nil
            }
            try fileManager.createDirectory(at: destinationRoot, withIntermediateDirectories: true)
            let retryFD = open(destinationRoot.path, O_RDONLY | O_DIRECTORY)
            if retryFD >= 0 {
                return retryFD
            }
        }

        throw CommitEngineError.moveFailed("Failed to open destination root directory: \(lastErrnoMessage())")
    }

    private func openDirectoryComponentNoFollow(_ component: String, in parentFD: Int32) throws -> Int32? {
        let nextFD = openat(parentFD, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        if nextFD >= 0 {
            return nextFD
        }

        let openErr = errno
        if isSymbolicLink(component, in: parentFD) || openErr == ELOOP {
            throw CommitEngineError.symlinkNotAllowed(
                "Destination path contains symbolic link: \(component)"
            )
        }
        if openErr == ENOENT {
            return nil
        }

        throw CommitEngineError.moveFailed(
            "Destination directory check failed for \(component): \(String(cString: strerror(openErr)))"
        )
    }

    private func validateExistingDestinationPath(_ path: String) throws {
        let (directoryComponents, filename) = try relativePathComponents(for: path)
        guard var currentFD = try openDestinationRootDirectory(createIfMissing: false) else {
            return
        }

        for component in directoryComponents {
            let nextFD: Int32?
            do {
                nextFD = try openDirectoryComponentNoFollow(component, in: currentFD)
            } catch {
                close(currentFD)
                throw error
            }
            close(currentFD)
            guard let openedFD = nextFD else {
                return
            }
            currentFD = openedFD
        }

        defer { close(currentFD) }
        if isSymbolicLink(filename, in: currentFD) {
            throw CommitEngineError.symlinkNotAllowed(
                "Destination path is a symbolic link: \(filename)"
            )
        }
    }

    private func openOrCreateSafeDestinationDirectory(
        for finalPath: String
    ) throws -> (directoryFD: Int32, filename: String) {
        let (directoryComponents, filename) = try relativePathComponents(for: finalPath)
        guard var currentFD = try openDestinationRootDirectory(createIfMissing: true) else {
            throw CommitEngineError.moveFailed("Failed to open destination root directory")
        }

        do {
            for component in directoryComponents {
                if let existingFD = try openDirectoryComponentNoFollow(component, in: currentFD) {
                    close(currentFD)
                    currentFD = existingFD
                    continue
                }

                if mkdirat(currentFD, component, 0o755) != 0 && errno != EEXIST {
                    throw CommitEngineError.moveFailed(
                        "Failed to create final directory \(component): \(lastErrnoMessage())"
                    )
                }

                guard let createdFD = try openDirectoryComponentNoFollow(component, in: currentFD) else {
                    throw CommitEngineError.moveFailed(
                        "Failed to open created final directory \(component)"
                    )
                }
                close(currentFD)
                currentFD = createdFD
            }

            try checkDestinationEntryAbsentOrFail(in: currentFD, filename: filename)
            return (currentFD, filename)
        } catch {
            close(currentFD)
            throw error
        }
    }

    private func openExistingDestinationFileForHash(atPath path: String) throws -> Int32? {
        let (directoryComponents, filename) = try relativePathComponents(for: path)
        guard var currentFD = try openDestinationRootDirectory(createIfMissing: false) else {
            return nil
        }

        for component in directoryComponents {
            let nextFD: Int32?
            do {
                nextFD = try openDirectoryComponentNoFollow(component, in: currentFD)
            } catch {
                close(currentFD)
                throw error
            }
            close(currentFD)
            guard let openedFD = nextFD else {
                return nil
            }
            currentFD = openedFD
        }

        defer { close(currentFD) }

        let fileFD = openat(currentFD, filename, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fileFD >= 0 else {
            let openErr = errno
            if isSymbolicLink(filename, in: currentFD) || openErr == ELOOP {
                throw CommitEngineError.symlinkNotAllowed(
                    "Destination path is a symbolic link: \(filename)"
                )
            }
            if openErr == ENOENT {
                return nil
            }
            throw CommitEngineError.hashFailed(
                "Failed to open existing destination file: \(String(cString: strerror(openErr)))"
            )
        }

        var attributes = stat()
        guard fstat(fileFD, &attributes) == 0 else {
            let msg = lastErrnoMessage()
            close(fileFD)
            throw CommitEngineError.hashFailed("Failed to stat existing destination file: \(msg)")
        }

        guard (attributes.st_mode & S_IFMT) == S_IFREG else {
            close(fileFD)
            return nil
        }

        clearNonBlockingFlag(on: fileFD)
        return fileFD
    }

    private func checkDestinationEntryAbsentOrFail(in directoryFD: Int32, filename: String) throws {
        var st = stat()
        if fstatat(directoryFD, filename, &st, AT_SYMLINK_NOFOLLOW) == 0 {
            if (st.st_mode & S_IFMT) == S_IFLNK {
                throw CommitEngineError.symlinkNotAllowed("Destination path is a symbolic link: \(filename)")
            }
            throw DestinationExistsRaceError.destinationNowExists
        }

        if errno != ENOENT {
            throw CommitEngineError.moveFailed("Failed to inspect destination entry \(filename): \(lastErrnoMessage())")
        }
    }

    private func isSymbolicLink(_ name: String, in directoryFD: Int32) -> Bool {
        var st = stat()
        guard fstatat(directoryFD, name, &st, AT_SYMLINK_NOFOLLOW) == 0 else {
            return false
        }
        return (st.st_mode & S_IFMT) == S_IFLNK
    }

    private func clearNonBlockingFlag(on fd: Int32) {
        let currentFlags = fcntl(fd, F_GETFL)
        if currentFlags >= 0, (currentFlags & O_NONBLOCK) != 0 {
            _ = fcntl(fd, F_SETFL, currentFlags & ~O_NONBLOCK)
        }
    }

    private func lastErrnoMessage() -> String {
        String(cString: strerror(errno))
    }

    private func pathByAppendingCollisionSuffix(basePath: String, suffix: Int) -> String {
        CollisionFilenameBuilder.pathByAppendingCollisionSuffix(basePath: basePath, suffix: suffix)
    }

    private func normalizePath(_ path: String) -> String {
        URL(fileURLWithPath: path, isDirectory: false).standardizedFileURL.path
    }

    private func isCrossVolumeMoveError(_ error: Error) -> Bool {
        containsErrorCode(error, domain: NSPOSIXErrorDomain, code: Int(EXDEV))
    }

    private func isDestinationExistsError(_ error: Error) -> Bool {
        containsErrorCode(error, domain: NSCocoaErrorDomain, code: NSFileWriteFileExistsError)
            || containsErrorCode(error, domain: NSPOSIXErrorDomain, code: Int(EEXIST))
    }

    private func containsErrorCode(_ error: Error, domain: String, code: Int) -> Bool {
        let nsError = error as NSError
        if nsError.domain == domain, nsError.code == code {
            return true
        }

        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            return containsErrorCode(underlying, domain: domain, code: code)
        }

        return false
    }
}

private struct SingleFileError: Error {
    let failure: StagingCommitEngine.FileFailure
}

private struct CommitSHA256Hasher {
    private var context = CC_SHA256_CTX()

    init() {
        CC_SHA256_Init(&context)
    }

    mutating func update(bytes: [UInt8], count: Int) {
        bytes.withUnsafeBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else {
                return
            }
            CC_SHA256_Update(&context, baseAddress, CC_LONG(count))
        }
    }

    mutating func finalizeHex() -> String {
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        CC_SHA256_Final(&digest, &context)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

private enum DestinationExistsRaceError: Error {
    case destinationNowExists
}

private enum CommitEngineError: LocalizedError {
    case moveFailed(String)
    case crossVolumeFallbackFailed(String)
    case hashFailed(String)
    case collisionLimitExceeded
    case symlinkNotAllowed(String)
    case outsideDestinationRoot(String)

    var errorDescription: String? {
        switch self {
        case .moveFailed(let message):
            return message
        case .crossVolumeFallbackFailed(let message):
            return message
        case .hashFailed(let message):
            return message
        case .collisionLimitExceeded:
            return "Collision suffix limit exceeded"
        case .symlinkNotAllowed(let message):
            return message
        case .outsideDestinationRoot(let message):
            return message
        }
    }
}
