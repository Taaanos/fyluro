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
        let bytesCopied: Int64
        let sourceHashSHA256: String
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

    private let configuration: Configuration
    private let fileManager: FileManager
    private let mediaTypeDirectoryResolver: MediaTypeDirectoryResolver

    init(configuration: Configuration = Configuration(), fileManager: FileManager = .default) {
        self.configuration = configuration
        self.fileManager = fileManager
        self.mediaTypeDirectoryResolver = MediaTypeDirectoryResolver(fileManager: fileManager)
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

        for (index, file) in files.enumerated() {
            do {
                let result = try commitSingle(file)
                results.append(result)
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

    private func commitSingle(_ job: FileJob) throws -> FileResult {
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
                resolution = try resolveCommitPath(for: job)
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
                let finalURL = URL(fileURLWithPath: finalPath, isDirectory: false)
                let finalDirURL = finalURL.deletingLastPathComponent()
                do {
                    try fileManager.createDirectory(at: finalDirURL, withIntermediateDirectories: true)
                } catch {
                    throw SingleFileError(failure: makeFailure(
                        message: "Failed to create final directory: \(error.localizedDescription)",
                        attemptedFinalPath: finalPath
                    ))
                }

                do {
                    let moveStrategy = try moveStagingToFinal(
                        stagingPath: job.stagingPath,
                        finalPath: finalPath
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

    private func resolveCommitPath(for job: FileJob) throws -> CommitResolution {
        let basePath = mediaTypeDirectoryResolver.resolvePath(job.plannedFinalPath)
        if !fileManager.fileExists(atPath: basePath) {
            return .commit(finalPath: basePath, collisionSuffix: nil)
        }

        if try isDuplicate(existingPath: basePath, expectedBytes: job.bytesCopied, sourceHash: job.sourceHashSHA256) {
            return .duplicate(finalPath: basePath, collisionSuffix: nil)
        }

        var suffix = 1
        while suffix <= configuration.maxCollisionSuffix {
            let candidate = normalizePath(pathByAppendingCollisionSuffix(basePath: basePath, suffix: suffix))
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

    private func moveStagingToFinal(stagingPath: String, finalPath: String) throws -> MoveStrategy {
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

    private func isDuplicate(existingPath: String, expectedBytes: Int64, sourceHash: String) throws -> Bool {
        guard let attributes = try? fileManager.attributesOfItem(atPath: existingPath),
              let existingSize = (attributes[.size] as? NSNumber)?.int64Value else {
            return false
        }

        guard existingSize == expectedBytes else {
            return false
        }

        let existingHash = try hashFileSHA256(path: existingPath)
        return existingHash == sourceHash
    }

    private func hashFileSHA256(path: String) throws -> String {
        let fileURL = URL(fileURLWithPath: path, isDirectory: false)
        guard let stream = InputStream(url: fileURL) else {
            throw CommitEngineError.hashFailed("Failed to open hash stream")
        }

        stream.open()
        defer { stream.close() }

        var hasher = CommitSHA256Hasher()
        var buffer = [UInt8](repeating: 0, count: configuration.chunkSize)

        while stream.hasBytesAvailable {
            let bytesRead = stream.read(&buffer, maxLength: buffer.count)
            if bytesRead < 0 {
                throw CommitEngineError.hashFailed(
                    "Read failed while hashing: \(stream.streamError?.localizedDescription ?? "unknown")"
                )
            }
            if bytesRead == 0 {
                break
            }

            hasher.update(bytes: buffer, count: bytesRead)
        }

        return hasher.finalizeHex()
    }

    private func pathByAppendingCollisionSuffix(basePath: String, suffix: Int) -> String {
        let filename = (basePath as NSString).lastPathComponent
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
        }
    }
}
