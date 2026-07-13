import CommonCrypto
import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

struct StagingCopyEngine {
    struct Configuration {
        let verifyAfterCopy: Bool
        let maxParallelCopies: Int
        let chunkSize: Int

        init(
            verifyAfterCopy: Bool = true,
            maxParallelCopies: Int = 2,
            chunkSize: Int = 1_048_576
        ) {
            self.verifyAfterCopy = verifyAfterCopy
            self.maxParallelCopies = maxParallelCopies
            self.chunkSize = chunkSize
        }
    }

    struct FileJob {
        let relativePath: String
        let sourcePath: String
        let stagingPath: String
        let finalPath: String
        let expectedBytes: Int64
    }

    struct FileResult {
        let relativePath: String
        let sourcePath: String
        let stagingPath: String
        let finalPath: String
        let bytesCopied: Int64
        let sourceHashSHA256: String
        let verifiedHashSHA256: String?
        let verificationSkipped: Bool
        let copyDurationMS: Int
        let verifyDurationMS: Int
    }

    struct FileFailure {
        let relativePath: String
        let sourcePath: String
        let stagingPath: String
        let finalPath: String
        let phase: IngestPhase
        let message: String
        let expectedBytes: Int64?
        let actualBytes: Int64?
        let expectedHashSHA256: String?
        let actualHashSHA256: String?
        let copyDurationMS: Int
        let verifyDurationMS: Int
    }

    enum Event {
        case started(FileJob)
        case finished(FileJob)
    }

    enum EngineError: Error {
        case invalidConfiguration(String)
        case runFailed(partialResults: [FileResult], failure: FileFailure)
    }

    private let configuration: Configuration
    private let fileManager: FileManager
    private let onEvent: ((Event) -> Void)?
    private let onBeforeCopy: ((FileJob) throws -> Void)?
    private let onPreVerify: ((FileJob) -> Void)?
    private let onProgress: ((FileJob, Int64) -> Void)?
    private let shouldCancel: (() -> Bool)?

    init(
        configuration: Configuration = Configuration(),
        fileManager: FileManager = .default,
        onEvent: ((Event) -> Void)? = nil,
        onBeforeCopy: ((FileJob) throws -> Void)? = nil,
        onPreVerify: ((FileJob) -> Void)? = nil,
        onProgress: ((FileJob, Int64) -> Void)? = nil,
        shouldCancel: (() -> Bool)? = nil
    ) {
        self.configuration = configuration
        self.fileManager = fileManager
        self.onEvent = onEvent
        self.onBeforeCopy = onBeforeCopy
        self.onPreVerify = onPreVerify
        self.onProgress = onProgress
        self.shouldCancel = shouldCancel
    }

    func copyToStaging(files: [FileJob]) throws -> [FileResult] {
        guard configuration.maxParallelCopies > 0 else {
            throw EngineError.invalidConfiguration("maxParallelCopies must be greater than 0")
        }
        guard configuration.chunkSize > 0 else {
            throw EngineError.invalidConfiguration("chunkSize must be greater than 0")
        }
        guard !files.isEmpty else {
            return []
        }

        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = configuration.maxParallelCopies
        queue.qualityOfService = .utility

        let lock = NSLock()
        var firstFailure: FileFailure?
        var resultsByIndex: [Int: FileResult] = [:]

        for (index, file) in files.enumerated() {
            queue.addOperation {
                lock.lock()
                let shouldSkip = firstFailure != nil
                lock.unlock()
                if shouldSkip {
                    return
                }

                onEvent?(.started(file))

                do {
                    let result = try copySingleFile(file)
                    lock.lock()
                    resultsByIndex[index] = result
                    lock.unlock()
                } catch let singleError as SingleFileError {
                    lock.lock()
                    if firstFailure == nil {
                        firstFailure = singleError.failure
                        queue.cancelAllOperations()
                    }
                    lock.unlock()
                } catch {
                    lock.lock()
                    if firstFailure == nil {
                        firstFailure = FileFailure(
                            relativePath: file.relativePath,
                            sourcePath: file.sourcePath,
                            stagingPath: file.stagingPath,
                            finalPath: file.finalPath,
                            phase: .copy,
                            message: error.localizedDescription,
                            expectedBytes: nil,
                            actualBytes: nil,
                            expectedHashSHA256: nil,
                            actualHashSHA256: nil,
                            copyDurationMS: 0,
                            verifyDurationMS: 0
                        )
                        queue.cancelAllOperations()
                    }
                    lock.unlock()
                }

                onEvent?(.finished(file))
            }
        }

        queue.waitUntilAllOperationsAreFinished()

        let orderedPartial = files.enumerated().compactMap { index, _ in
            resultsByIndex[index]
        }

        if let firstFailure {
            throw EngineError.runFailed(partialResults: orderedPartial, failure: firstFailure)
        }

        return orderedPartial
    }

    private func copySingleFile(_ job: FileJob) throws -> FileResult {
        func elapsedMilliseconds(since start: Date) -> Int {
            Int((Date().timeIntervalSince(start) * 1_000).rounded())
        }

        let copyPhaseStartedAt = Date()

        func makeFailure(
            phase: IngestPhase,
            message: String,
            expectedBytes: Int64? = nil,
            actualBytes: Int64? = nil,
            expectedHashSHA256: String? = nil,
            actualHashSHA256: String? = nil,
            copyDurationMS: Int? = nil,
            verifyDurationMS: Int = 0
        ) -> FileFailure {
            FileFailure(
                relativePath: job.relativePath,
                sourcePath: job.sourcePath,
                stagingPath: job.stagingPath,
                finalPath: job.finalPath,
                phase: phase,
                message: message,
                expectedBytes: expectedBytes,
                actualBytes: actualBytes,
                expectedHashSHA256: expectedHashSHA256,
                actualHashSHA256: actualHashSHA256,
                copyDurationMS: copyDurationMS ?? elapsedMilliseconds(since: copyPhaseStartedAt),
                verifyDurationMS: verifyDurationMS
            )
        }

        let stagingURL = URL(fileURLWithPath: job.stagingPath, isDirectory: false)
        let stagingDirURL = stagingURL.deletingLastPathComponent()
        let filename = stagingURL.lastPathComponent
        let tempName = ".\(filename).rollkeep-\(UUID().uuidString.lowercased()).tmp"
        let tempURL = stagingDirURL.appendingPathComponent(tempName, isDirectory: false)

        do {
            do {
                try onBeforeCopy?(job)
            } catch {
                throw SingleFileError(failure: makeFailure(
                    phase: .copy,
                    message: error.localizedDescription
                ))
            }

            try fileManager.createDirectory(at: stagingDirURL, withIntermediateDirectories: true)

            if fileManager.fileExists(atPath: job.stagingPath) {
                throw SingleFileError(failure: makeFailure(
                    phase: .copy,
                    message: "Staging destination already exists"
                ))
            }

            guard fileManager.createFile(atPath: tempURL.path, contents: nil) else {
                throw SingleFileError(failure: makeFailure(
                    phase: .copy,
                    message: "Failed to create temporary staging file"
                ))
            }

            let sourceFD = try openValidatedSourceFileDescriptor(job: job, makeFailure: makeFailure)
            guard let tempStream = OutputStream(url: tempURL, append: false) else {
                close(sourceFD)
                throw SingleFileError(failure: makeFailure(
                    phase: .copy,
                    message: "Failed to open temporary staging output stream"
                ))
            }

            tempStream.open()
            defer {
                close(sourceFD)
                tempStream.close()
            }

            var hasher = SHA256Hasher()
            var bytesCopied: Int64 = 0
            var buffer = [UInt8](repeating: 0, count: configuration.chunkSize)

            while true {
                if shouldCancel?() == true {
                    throw SingleFileError(failure: makeFailure(
                        phase: .copy,
                        message: "Ingest cancelled during copy"
                    ))
                }

                let bytesRead = try readFromSourceFileDescriptor(sourceFD, into: &buffer, makeFailure: makeFailure)
                if bytesRead == 0 {
                    break
                }

                var written = 0
                while written < bytesRead {
                    let writeCount = buffer.withUnsafeMutableBufferPointer { pointer in
                        guard let baseAddress = pointer.baseAddress else {
                            return -1
                        }
                        return tempStream.write(baseAddress.advanced(by: written), maxLength: bytesRead - written)
                    }
                    if writeCount <= 0 {
                        throw SingleFileError(failure: makeFailure(
                            phase: .copy,
                            message: "Write failed: \(tempStream.streamError?.localizedDescription ?? "unknown")"
                        ))
                    }
                    written += writeCount
                }

                hasher.update(bytes: buffer, count: bytesRead)
                bytesCopied += Int64(bytesRead)
                onProgress?(job, bytesCopied)
            }

            if bytesCopied != job.expectedBytes {
                throw SingleFileError(failure: makeFailure(
                    phase: .copy,
                    message: "Copied bytes (\(bytesCopied)) do not match expected bytes (\(job.expectedBytes))",
                    expectedBytes: job.expectedBytes,
                    actualBytes: bytesCopied
                ))
            }

            let sourceHash = hasher.finalizeHex()

            do {
                try fileManager.moveItem(at: tempURL, to: stagingURL)
            } catch {
                throw SingleFileError(failure: makeFailure(
                    phase: .copy,
                    message: "Failed to atomically rename temporary staging file: \(error.localizedDescription)"
                ))
            }

            let copyDurationMS = elapsedMilliseconds(since: copyPhaseStartedAt)
            var verifiedHash: String?
            var verifyDurationMS = 0
            if configuration.verifyAfterCopy {
                let verifyPhaseStartedAt = Date()
                onPreVerify?(job)
                let verification: (hash: String, bytes: Int64)
                do {
                    verification = try hashFileSHA256(path: job.stagingPath, job: job)
                } catch let verificationError as SingleFileError {
                    let failure = verificationError.failure
                    throw SingleFileError(failure: makeFailure(
                        phase: failure.phase,
                        message: failure.message,
                        expectedBytes: failure.expectedBytes,
                        actualBytes: failure.actualBytes,
                        expectedHashSHA256: failure.expectedHashSHA256,
                        actualHashSHA256: failure.actualHashSHA256,
                        copyDurationMS: copyDurationMS,
                        verifyDurationMS: elapsedMilliseconds(since: verifyPhaseStartedAt)
                    ))
                }
                verifyDurationMS = elapsedMilliseconds(since: verifyPhaseStartedAt)
                verifiedHash = verification.hash

                if verification.hash != sourceHash {
                    throw SingleFileError(failure: makeFailure(
                        phase: .verify,
                        message: "Read-back verification failed: hash mismatch",
                        expectedBytes: bytesCopied,
                        actualBytes: verification.bytes,
                        expectedHashSHA256: sourceHash,
                        actualHashSHA256: verification.hash,
                        copyDurationMS: copyDurationMS,
                        verifyDurationMS: verifyDurationMS
                    ))
                }

                if verification.bytes != bytesCopied {
                    throw SingleFileError(failure: makeFailure(
                        phase: .verify,
                        message: "Read-back verification failed: size mismatch",
                        expectedBytes: bytesCopied,
                        actualBytes: verification.bytes,
                        expectedHashSHA256: sourceHash,
                        actualHashSHA256: verification.hash,
                        copyDurationMS: copyDurationMS,
                        verifyDurationMS: verifyDurationMS
                    ))
                }
            }

            return FileResult(
                relativePath: job.relativePath,
                sourcePath: job.sourcePath,
                stagingPath: job.stagingPath,
                finalPath: job.finalPath,
                bytesCopied: bytesCopied,
                sourceHashSHA256: sourceHash,
                verifiedHashSHA256: verifiedHash,
                verificationSkipped: !configuration.verifyAfterCopy,
                copyDurationMS: copyDurationMS,
                verifyDurationMS: verifyDurationMS
            )
        } catch {
            try? fileManager.removeItem(at: tempURL)
            throw error
        }
    }

    private func openValidatedSourceFileDescriptor(
        job: FileJob,
        makeFailure: (IngestPhase, String, Int64?, Int64?, String?, String?, Int?, Int) -> FileFailure
    ) throws -> Int32 {
        let flags = O_RDONLY | O_NOFOLLOW
        let fd = open(job.sourcePath, flags)
        guard fd >= 0 else {
            if errno == ELOOP {
                throw SingleFileError(failure: makeFailure(
                    .copy,
                    "symlink_not_allowed: source path is a symbolic link",
                    nil,
                    nil,
                    nil,
                    nil,
                    nil,
                    0
                ))
            }
            throw SingleFileError(failure: makeFailure(
                .copy,
                "Failed to open source file descriptor: \(lastErrnoMessage())",
                nil,
                nil,
                nil,
                nil,
                nil,
                0
            ))
        }

        var attributes = stat()
        guard fstat(fd, &attributes) == 0 else {
            let message = lastErrnoMessage()
            close(fd)
            throw SingleFileError(failure: makeFailure(
                .copy,
                "Failed to stat source file descriptor: \(message)",
                nil,
                nil,
                nil,
                nil,
                nil,
                0
            ))
        }

        guard (attributes.st_mode & S_IFMT) == S_IFREG else {
            close(fd)
            throw SingleFileError(failure: makeFailure(
                .copy,
                "non_regular_source: source path is not a regular file",
                nil,
                nil,
                nil,
                nil,
                nil,
                0
            ))
        }

        let sourceBytes = Int64(attributes.st_size)
        guard sourceBytes == job.expectedBytes else {
            close(fd)
            throw SingleFileError(failure: makeFailure(
                .copy,
                "Source bytes (\(sourceBytes)) do not match expected bytes (\(job.expectedBytes))",
                job.expectedBytes,
                sourceBytes,
                nil,
                nil,
                nil,
                0
            ))
        }

        return fd
    }

    private func readFromSourceFileDescriptor(
        _ fd: Int32,
        into buffer: inout [UInt8],
        makeFailure: (IngestPhase, String, Int64?, Int64?, String?, String?, Int?, Int) -> FileFailure
    ) throws -> Int {
        let bufferCount = buffer.count
        let bytesRead: Int = buffer.withUnsafeMutableBytes { mutableBytes in
            guard let baseAddress = mutableBytes.baseAddress else {
                return -1
            }
            return read(fd, baseAddress, bufferCount)
        }

        if bytesRead < 0 {
            throw SingleFileError(failure: makeFailure(
                .copy,
                "Read failed: \(lastErrnoMessage())",
                nil,
                nil,
                nil,
                nil,
                nil,
                0
            ))
        }

        return bytesRead
    }

    private func hashFileSHA256(path: String, job: FileJob) throws -> (hash: String, bytes: Int64) {
        let fileURL = URL(fileURLWithPath: path, isDirectory: false)
        guard let stream = InputStream(url: fileURL) else {
            throw SingleFileError(failure: FileFailure(
                relativePath: job.relativePath,
                sourcePath: job.sourcePath,
                stagingPath: job.stagingPath,
                finalPath: job.finalPath,
                phase: .verify,
                message: "Failed to open read-back stream",
                expectedBytes: nil,
                actualBytes: nil,
                expectedHashSHA256: nil,
                actualHashSHA256: nil,
                copyDurationMS: 0,
                verifyDurationMS: 0
            ))
        }

        stream.open()
        defer {
            stream.close()
        }

        var hasher = SHA256Hasher()
        var totalBytes: Int64 = 0
        var buffer = [UInt8](repeating: 0, count: configuration.chunkSize)

        while stream.hasBytesAvailable {
            let bytesRead = stream.read(&buffer, maxLength: buffer.count)
            if bytesRead < 0 {
                throw SingleFileError(failure: FileFailure(
                    relativePath: job.relativePath,
                    sourcePath: job.sourcePath,
                    stagingPath: job.stagingPath,
                    finalPath: job.finalPath,
                    phase: .verify,
                    message: "Read-back read failed: \(stream.streamError?.localizedDescription ?? "unknown")",
                    expectedBytes: nil,
                    actualBytes: nil,
                    expectedHashSHA256: nil,
                    actualHashSHA256: nil,
                    copyDurationMS: 0,
                    verifyDurationMS: 0
                ))
            }
            if bytesRead == 0 {
                break
            }

            hasher.update(bytes: buffer, count: bytesRead)
            totalBytes += Int64(bytesRead)
        }

        return (hasher.finalizeHex(), totalBytes)
    }
}

private struct SingleFileError: Error {
    let failure: StagingCopyEngine.FileFailure
}

private struct SHA256Hasher {
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

private func lastErrnoMessage() -> String {
    String(cString: strerror(errno))
}
