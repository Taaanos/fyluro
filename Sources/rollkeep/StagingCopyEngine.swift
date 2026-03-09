import CommonCrypto
import Foundation

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
    }

    struct FileFailure {
        let relativePath: String
        let sourcePath: String
        let stagingPath: String
        let phase: IngestPhase
        let message: String
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

    init(
        configuration: Configuration = Configuration(),
        fileManager: FileManager = .default,
        onEvent: ((Event) -> Void)? = nil
    ) {
        self.configuration = configuration
        self.fileManager = fileManager
        self.onEvent = onEvent
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
                            phase: .copy,
                            message: error.localizedDescription
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
        let stagingURL = URL(fileURLWithPath: job.stagingPath, isDirectory: false)
        let stagingDirURL = stagingURL.deletingLastPathComponent()
        let filename = stagingURL.lastPathComponent
        let tempName = ".\(filename).rollkeep-\(UUID().uuidString.lowercased()).tmp"
        let tempURL = stagingDirURL.appendingPathComponent(tempName, isDirectory: false)

        do {
            try fileManager.createDirectory(at: stagingDirURL, withIntermediateDirectories: true)

            if fileManager.fileExists(atPath: job.stagingPath) {
                throw SingleFileError(failure: FileFailure(
                    relativePath: job.relativePath,
                    sourcePath: job.sourcePath,
                    stagingPath: job.stagingPath,
                    phase: .copy,
                    message: "Staging destination already exists"
                ))
            }

            guard fileManager.createFile(atPath: tempURL.path, contents: nil) else {
                throw SingleFileError(failure: FileFailure(
                    relativePath: job.relativePath,
                    sourcePath: job.sourcePath,
                    stagingPath: job.stagingPath,
                    phase: .copy,
                    message: "Failed to create temporary staging file"
                ))
            }

            let sourceURL = URL(fileURLWithPath: job.sourcePath, isDirectory: false)
            guard let sourceStream = InputStream(url: sourceURL) else {
                throw SingleFileError(failure: FileFailure(
                    relativePath: job.relativePath,
                    sourcePath: job.sourcePath,
                    stagingPath: job.stagingPath,
                    phase: .copy,
                    message: "Failed to open source input stream"
                ))
            }
            guard let tempStream = OutputStream(url: tempURL, append: false) else {
                throw SingleFileError(failure: FileFailure(
                    relativePath: job.relativePath,
                    sourcePath: job.sourcePath,
                    stagingPath: job.stagingPath,
                    phase: .copy,
                    message: "Failed to open temporary staging output stream"
                ))
            }

            sourceStream.open()
            tempStream.open()
            defer {
                sourceStream.close()
                tempStream.close()
            }

            var hasher = SHA256Hasher()
            var bytesCopied: Int64 = 0
            var buffer = [UInt8](repeating: 0, count: configuration.chunkSize)

            while sourceStream.hasBytesAvailable {
                let bytesRead = sourceStream.read(&buffer, maxLength: buffer.count)
                if bytesRead < 0 {
                    throw SingleFileError(failure: FileFailure(
                        relativePath: job.relativePath,
                        sourcePath: job.sourcePath,
                        stagingPath: job.stagingPath,
                        phase: .copy,
                        message: "Read failed: \(sourceStream.streamError?.localizedDescription ?? "unknown")"
                    ))
                }
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
                        throw SingleFileError(failure: FileFailure(
                            relativePath: job.relativePath,
                            sourcePath: job.sourcePath,
                            stagingPath: job.stagingPath,
                            phase: .copy,
                            message: "Write failed: \(tempStream.streamError?.localizedDescription ?? "unknown")"
                        ))
                    }
                    written += writeCount
                }

                hasher.update(bytes: buffer, count: bytesRead)
                bytesCopied += Int64(bytesRead)
            }

            if bytesCopied != job.expectedBytes {
                throw SingleFileError(failure: FileFailure(
                    relativePath: job.relativePath,
                    sourcePath: job.sourcePath,
                    stagingPath: job.stagingPath,
                    phase: .copy,
                    message: "Copied bytes (\(bytesCopied)) do not match expected bytes (\(job.expectedBytes))"
                ))
            }

            let sourceHash = hasher.finalizeHex()

            var verifiedHash: String?
            if configuration.verifyAfterCopy {
                let verification = try hashFileSHA256(path: tempURL.path)
                verifiedHash = verification.hash

                guard verification.hash == sourceHash, verification.bytes == bytesCopied else {
                    throw SingleFileError(failure: FileFailure(
                        relativePath: job.relativePath,
                        sourcePath: job.sourcePath,
                        stagingPath: job.stagingPath,
                        phase: .verify,
                        message: "Read-back verification failed (hash or size mismatch)"
                    ))
                }
            }

            do {
                try fileManager.moveItem(at: tempURL, to: stagingURL)
            } catch {
                throw SingleFileError(failure: FileFailure(
                    relativePath: job.relativePath,
                    sourcePath: job.sourcePath,
                    stagingPath: job.stagingPath,
                    phase: .copy,
                    message: "Failed to atomically rename temporary staging file: \(error.localizedDescription)"
                ))
            }

            return FileResult(
                relativePath: job.relativePath,
                sourcePath: job.sourcePath,
                stagingPath: job.stagingPath,
                finalPath: job.finalPath,
                bytesCopied: bytesCopied,
                sourceHashSHA256: sourceHash,
                verifiedHashSHA256: verifiedHash,
                verificationSkipped: !configuration.verifyAfterCopy
            )
        } catch {
            try? fileManager.removeItem(at: tempURL)
            throw error
        }
    }

    private func hashFileSHA256(path: String) throws -> (hash: String, bytes: Int64) {
        let fileURL = URL(fileURLWithPath: path, isDirectory: false)
        guard let stream = InputStream(url: fileURL) else {
            throw SingleFileError(failure: FileFailure(
                relativePath: path,
                sourcePath: path,
                stagingPath: path,
                phase: .verify,
                message: "Failed to open read-back stream"
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
                    relativePath: path,
                    sourcePath: path,
                    stagingPath: path,
                    phase: .verify,
                    message: "Read-back read failed: \(stream.streamError?.localizedDescription ?? "unknown")"
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
