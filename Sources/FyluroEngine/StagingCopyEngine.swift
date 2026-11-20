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
        let hardwareVerification: Bool
        let maxParallelCopies: Int
        let chunkSize: Int

        init(
            verifyAfterCopy: Bool = true,
            hardwareVerification: Bool = true,
            maxParallelCopies: Int = 1,
            chunkSize: Int = 1_048_576
        ) {
            self.verifyAfterCopy = verifyAfterCopy
            self.hardwareVerification = hardwareVerification
            self.maxParallelCopies = maxParallelCopies
            self.chunkSize = chunkSize
        }
    }

    struct FileDescriptorHooks {
        var disableStagingWriteCache: (Int32) -> Int32
        var syncStagingVolume: (Int32) -> Int32
        var disableReadBackCache: (Int32) -> Int32

        static let system = FileDescriptorHooks(
            disableStagingWriteCache: { fd in
                disableOSCache(fd)
            },
            syncStagingVolume: { fd in
                #if canImport(Darwin)
                if fcntl(fd, F_FULLFSYNC) == 0 {
                    return 0
                }
                if errno != ENOTSUP && errno != EINVAL && errno != ENOTTY {
                    return -1
                }
                #endif
                return fsync(fd)
            },
            disableReadBackCache: { fd in
                disableOSCache(fd)
            }
        )

        private static func disableOSCache(_ fd: Int32) -> Int32 {
            #if canImport(Darwin)
            if fcntl(fd, F_NOCACHE, 1) == 0 {
                return 0
            }
            if errno == ENOTSUP || errno == EINVAL || errno == ENOTTY {
                return 0
            }
            return -1
            #else
            return 0
            #endif
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

    private struct StagedCopyRecord {
        let job: FileJob
        let bytesCopied: Int64
        let sourceHashSHA256: String
        let copyDurationMS: Int

        func asUnverifiedResult() -> FileResult {
            FileResult(
                relativePath: job.relativePath,
                sourcePath: job.sourcePath,
                stagingPath: job.stagingPath,
                finalPath: job.finalPath,
                bytesCopied: bytesCopied,
                sourceHashSHA256: sourceHashSHA256,
                verifiedHashSHA256: nil,
                verificationSkipped: true,
                copyDurationMS: copyDurationMS,
                verifyDurationMS: 0
            )
        }
    }

    private let configuration: Configuration
    private let fileManager: FileManager
    private let fileDescriptorHooks: FileDescriptorHooks
    private let onEvent: ((Event) -> Void)?
    private let onBeforeCopy: ((FileJob) throws -> Void)?
    private let onPreVerify: ((FileJob) -> Void)?
    private let onProgress: ((FileJob, Int64) -> Void)?
    private let onVerifyPhaseStarted: (() -> Void)?
    private let onVerifyProgress: ((FileJob, Int64) -> Void)?
    private let onFileVerified: ((FileJob) -> Void)?
    private let shouldCancel: (() -> Bool)?

    init(
        configuration: Configuration = Configuration(),
        fileManager: FileManager = .default,
        fileDescriptorHooks: FileDescriptorHooks = .system,
        onEvent: ((Event) -> Void)? = nil,
        onBeforeCopy: ((FileJob) throws -> Void)? = nil,
        onPreVerify: ((FileJob) -> Void)? = nil,
        onProgress: ((FileJob, Int64) -> Void)? = nil,
        onVerifyPhaseStarted: (() -> Void)? = nil,
        onVerifyProgress: ((FileJob, Int64) -> Void)? = nil,
        onFileVerified: ((FileJob) -> Void)? = nil,
        shouldCancel: (() -> Bool)? = nil
    ) {
        self.configuration = configuration
        self.fileManager = fileManager
        self.fileDescriptorHooks = fileDescriptorHooks
        self.onEvent = onEvent
        self.onBeforeCopy = onBeforeCopy
        self.onPreVerify = onPreVerify
        self.onProgress = onProgress
        self.onVerifyPhaseStarted = onVerifyPhaseStarted
        self.onVerifyProgress = onVerifyProgress
        self.onFileVerified = onFileVerified
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

        // Pass 1: Copy all planned files to staging and capture source SHA-256 hashes in memory.
        let stagedRecords = try runCopyPass(files: files)

        // Single hardware barrier: drain the destination drive's write cache once after Pass 1.
        if configuration.hardwareVerification, let lastStaged = stagedRecords.last {
            try flushStagingVolume(anchor: lastStaged, allRecords: stagedRecords)
        }

        guard configuration.verifyAfterCopy else {
            return stagedRecords.map { $0.asUnverifiedResult() }
        }

        // Pass 2: Read back all staged files and verify SHA-256 hashes and byte counts.
        return try runVerifyPass(stagedRecords: stagedRecords)
    }

    private func runCopyPass(files: [FileJob]) throws -> [StagedCopyRecord] {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = configuration.maxParallelCopies
        queue.qualityOfService = .utility

        let lock = NSLock()
        var firstFailure: FileFailure?
        var stagedByIndex: [Int: StagedCopyRecord] = [:]

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
                    let record = try copySingleFileToStaging(file)
                    lock.lock()
                    stagedByIndex[index] = record
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

        let orderedRecords = files.enumerated().compactMap { index, _ in
            stagedByIndex[index]
        }

        if let firstFailure {
            throw EngineError.runFailed(
                partialResults: orderedRecords.map { $0.asUnverifiedResult() },
                failure: firstFailure
            )
        }

        return orderedRecords
    }

    private func flushStagingVolume(anchor: StagedCopyRecord, allRecords: [StagedCopyRecord]) throws {
        let fd = open(anchor.job.stagingPath, O_RDONLY)
        guard fd >= 0 else {
            let message = "Failed to open staged file for volume flush: \(lastErrnoMessage())"
            throw makeFlushFailure(anchor: anchor, allRecords: allRecords, message: message)
        }
        defer {
            close(fd)
        }

        if fileDescriptorHooks.syncStagingVolume(fd) != 0 {
            let message = "Failed to flush staging volume to disk: \(lastErrnoMessage())"
            throw makeFlushFailure(anchor: anchor, allRecords: allRecords, message: message)
        }
    }

    private func makeFlushFailure(
        anchor: StagedCopyRecord,
        allRecords: [StagedCopyRecord],
        message: String
    ) -> EngineError {
        let partialResults = allRecords.dropLast().map { $0.asUnverifiedResult() }
        let failure = FileFailure(
            relativePath: anchor.job.relativePath,
            sourcePath: anchor.job.sourcePath,
            stagingPath: anchor.job.stagingPath,
            finalPath: anchor.job.finalPath,
            phase: .copy,
            message: message,
            expectedBytes: anchor.job.expectedBytes,
            actualBytes: anchor.bytesCopied,
            expectedHashSHA256: anchor.sourceHashSHA256,
            actualHashSHA256: nil,
            copyDurationMS: anchor.copyDurationMS,
            verifyDurationMS: 0
        )
        return .runFailed(partialResults: partialResults, failure: failure)
    }

    private func runVerifyPass(stagedRecords: [StagedCopyRecord]) throws -> [FileResult] {
        onVerifyPhaseStarted?()

        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = configuration.maxParallelCopies
        queue.qualityOfService = .utility

        let lock = NSLock()
        var firstFailure: FileFailure?
        var failedIndex: Int?
        var verifiedByIndex: [Int: FileResult] = [:]

        for (index, record) in stagedRecords.enumerated() {
            queue.addOperation {
                lock.lock()
                let shouldSkip = firstFailure != nil
                lock.unlock()
                if shouldSkip {
                    return
                }

                do {
                    let result = try verifySingleStagedFile(record)
                    lock.lock()
                    let recordVerified = firstFailure == nil
                    if recordVerified {
                        verifiedByIndex[index] = result
                    }
                    lock.unlock()
                    if recordVerified {
                        onFileVerified?(record.job)
                    }
                } catch let singleError as SingleFileError {
                    lock.lock()
                    if firstFailure == nil {
                        firstFailure = singleError.failure
                        failedIndex = index
                        queue.cancelAllOperations()
                    }
                    lock.unlock()
                } catch {
                    lock.lock()
                    if firstFailure == nil {
                        firstFailure = FileFailure(
                            relativePath: record.job.relativePath,
                            sourcePath: record.job.sourcePath,
                            stagingPath: record.job.stagingPath,
                            finalPath: record.job.finalPath,
                            phase: .verify,
                            message: error.localizedDescription,
                            expectedBytes: record.bytesCopied,
                            actualBytes: nil,
                            expectedHashSHA256: record.sourceHashSHA256,
                            actualHashSHA256: nil,
                            copyDurationMS: record.copyDurationMS,
                            verifyDurationMS: 0
                        )
                        failedIndex = index
                        queue.cancelAllOperations()
                    }
                    lock.unlock()
                }
            }
        }

        queue.waitUntilAllOperationsAreFinished()

        if let firstFailure {
            let partialResults: [FileResult] = stagedRecords.enumerated().compactMap { index, record in
                if index == failedIndex {
                    return nil
                }
                return verifiedByIndex[index] ?? record.asUnverifiedResult()
            }
            throw EngineError.runFailed(partialResults: partialResults, failure: firstFailure)
        }

        return stagedRecords.indices.compactMap { verifiedByIndex[$0] }
    }

    private func copySingleFileToStaging(_ job: FileJob) throws -> StagedCopyRecord {
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
        // The temporary name has a fixed length. It must not contain the filename:
        // a legal 205-byte or longer filename would make the temporary name exceed
        // the 255-byte component limit and abort the run (KI-1).
        let tempName = ".fyluro-\(UUID().uuidString.lowercased()).tmp"
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
            var tempFD = open(tempURL.path, O_WRONLY | O_TRUNC)
            guard tempFD >= 0 else {
                let message = lastErrnoMessage()
                close(sourceFD)
                throw SingleFileError(failure: makeFailure(
                    phase: .copy,
                    message: "Failed to open temporary staging output stream: \(message)"
                ))
            }

            defer {
                close(sourceFD)
                if tempFD >= 0 {
                    close(tempFD)
                }
            }

            if configuration.hardwareVerification {
                if fileDescriptorHooks.disableStagingWriteCache(tempFD) != 0 {
                    throw SingleFileError(failure: makeFailure(
                        phase: .copy,
                        message: "Failed to disable staging write cache: \(lastErrnoMessage())"
                    ))
                }
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

                try writeToStagingFileDescriptor(
                    tempFD,
                    from: buffer,
                    count: bytesRead,
                    makeFailure: makeFailure
                )

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

            if close(tempFD) != 0 {
                tempFD = -1
                throw SingleFileError(failure: makeFailure(
                    phase: .copy,
                    message: "Failed to close temporary staging file: \(lastErrnoMessage())"
                ))
            }
            tempFD = -1

            let sourceHash = hasher.finalizeHex()

            do {
                try fileManager.moveItem(at: tempURL, to: stagingURL)
            } catch {
                throw SingleFileError(failure: makeFailure(
                    phase: .copy,
                    message: "Failed to atomically rename temporary staging file: \(error.localizedDescription)"
                ))
            }

            return StagedCopyRecord(
                job: job,
                bytesCopied: bytesCopied,
                sourceHashSHA256: sourceHash,
                copyDurationMS: elapsedMilliseconds(since: copyPhaseStartedAt)
            )
        } catch {
            try? fileManager.removeItem(at: tempURL)
            throw error
        }
    }

    private func verifySingleStagedFile(_ record: StagedCopyRecord) throws -> FileResult {
        func elapsedMilliseconds(since start: Date) -> Int {
            Int((Date().timeIntervalSince(start) * 1_000).rounded())
        }

        let job = record.job
        let verifyPhaseStartedAt = Date()

        func makeVerifyFailure(
            message: String,
            actualBytes: Int64? = nil,
            actualHashSHA256: String? = nil,
            verifyDurationMS: Int? = nil
        ) -> FileFailure {
            FileFailure(
                relativePath: job.relativePath,
                sourcePath: job.sourcePath,
                stagingPath: job.stagingPath,
                finalPath: job.finalPath,
                phase: .verify,
                message: message,
                expectedBytes: record.bytesCopied,
                actualBytes: actualBytes,
                expectedHashSHA256: record.sourceHashSHA256,
                actualHashSHA256: actualHashSHA256,
                copyDurationMS: record.copyDurationMS,
                verifyDurationMS: verifyDurationMS ?? elapsedMilliseconds(since: verifyPhaseStartedAt)
            )
        }

        if shouldCancel?() == true {
            throw SingleFileError(failure: makeVerifyFailure(message: "Ingest cancelled during verify"))
        }

        onPreVerify?(job)

        let verification: (hash: String, bytes: Int64)
        do {
            verification = try hashFileSHA256(path: job.stagingPath, job: job)
        } catch let verificationError as SingleFileError {
            let failure = verificationError.failure
            throw SingleFileError(failure: makeVerifyFailure(
                message: failure.message,
                actualBytes: failure.actualBytes,
                actualHashSHA256: failure.actualHashSHA256
            ))
        }

        let verifyDurationMS = elapsedMilliseconds(since: verifyPhaseStartedAt)

        if verification.hash != record.sourceHashSHA256 {
            throw SingleFileError(failure: makeVerifyFailure(
                message: "Read-back verification failed: hash mismatch",
                actualBytes: verification.bytes,
                actualHashSHA256: verification.hash,
                verifyDurationMS: verifyDurationMS
            ))
        }

        if verification.bytes != record.bytesCopied {
            throw SingleFileError(failure: makeVerifyFailure(
                message: "Read-back verification failed: size mismatch",
                actualBytes: verification.bytes,
                actualHashSHA256: verification.hash,
                verifyDurationMS: verifyDurationMS
            ))
        }

        return FileResult(
            relativePath: job.relativePath,
            sourcePath: job.sourcePath,
            stagingPath: job.stagingPath,
            finalPath: job.finalPath,
            bytesCopied: record.bytesCopied,
            sourceHashSHA256: record.sourceHashSHA256,
            verifiedHashSHA256: verification.hash,
            verificationSkipped: false,
            copyDurationMS: record.copyDurationMS,
            verifyDurationMS: verifyDurationMS
        )
    }

    private func openValidatedSourceFileDescriptor(
        job: FileJob,
        makeFailure: (IngestPhase, String, Int64?, Int64?, String?, String?, Int?, Int) -> FileFailure
    ) throws -> Int32 {
        let flags = O_RDONLY | O_NOFOLLOW | O_NONBLOCK
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

        // Clear O_NONBLOCK after verifying S_IFREG so subsequent reads block normally.
        let currentFlags = fcntl(fd, F_GETFL)
        if currentFlags >= 0, (currentFlags & O_NONBLOCK) != 0 {
            _ = fcntl(fd, F_SETFL, currentFlags & ~O_NONBLOCK)
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
        while true {
            let bytesRead: Int = buffer.withUnsafeMutableBytes { mutableBytes in
                guard let baseAddress = mutableBytes.baseAddress else {
                    return -1
                }
                return read(fd, baseAddress, bufferCount)
            }

            if bytesRead < 0 {
                if errno == EINTR {
                    continue
                }
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
    }

    private func writeToStagingFileDescriptor(
        _ fd: Int32,
        from buffer: [UInt8],
        count: Int,
        makeFailure: (IngestPhase, String, Int64?, Int64?, String?, String?, Int?, Int) -> FileFailure
    ) throws {
        var written = 0
        while written < count {
            let writeCount = buffer.withUnsafeBytes { rawBytes in
                guard let baseAddress = rawBytes.baseAddress else {
                    return -1
                }
                return write(fd, baseAddress.advanced(by: written), count - written)
            }
            if writeCount < 0 {
                if errno == EINTR {
                    continue
                }
                throw SingleFileError(failure: makeFailure(
                    .copy,
                    "Write failed: \(lastErrnoMessage())",
                    nil,
                    nil,
                    nil,
                    nil,
                    nil,
                    0
                ))
            }
            if writeCount == 0 {
                throw SingleFileError(failure: makeFailure(
                    .copy,
                    "Write failed: zero bytes written",
                    nil,
                    nil,
                    nil,
                    nil,
                    nil,
                    0
                ))
            }
            written += writeCount
        }
    }

    private func hashFileSHA256(path: String, job: FileJob) throws -> (hash: String, bytes: Int64) {
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else {
            throw SingleFileError(failure: FileFailure(
                relativePath: job.relativePath,
                sourcePath: job.sourcePath,
                stagingPath: job.stagingPath,
                finalPath: job.finalPath,
                phase: .verify,
                message: "Failed to open read-back stream: \(lastErrnoMessage())",
                expectedBytes: nil,
                actualBytes: nil,
                expectedHashSHA256: nil,
                actualHashSHA256: nil,
                copyDurationMS: 0,
                verifyDurationMS: 0
            ))
        }

        defer {
            close(fd)
        }

        if configuration.hardwareVerification {
            if fileDescriptorHooks.disableReadBackCache(fd) != 0 {
                throw SingleFileError(failure: FileFailure(
                    relativePath: job.relativePath,
                    sourcePath: job.sourcePath,
                    stagingPath: job.stagingPath,
                    finalPath: job.finalPath,
                    phase: .verify,
                    message: "Failed to disable read-back cache: \(lastErrnoMessage())",
                    expectedBytes: nil,
                    actualBytes: nil,
                    expectedHashSHA256: nil,
                    actualHashSHA256: nil,
                    copyDurationMS: 0,
                    verifyDurationMS: 0
                ))
            }
        }

        var hasher = SHA256Hasher()
        var totalBytes: Int64 = 0
        var buffer = [UInt8](repeating: 0, count: configuration.chunkSize)

        while true {
            if shouldCancel?() == true {
                throw SingleFileError(failure: FileFailure(
                    relativePath: job.relativePath,
                    sourcePath: job.sourcePath,
                    stagingPath: job.stagingPath,
                    finalPath: job.finalPath,
                    phase: .verify,
                    message: "Ingest cancelled during verify",
                    expectedBytes: nil,
                    actualBytes: nil,
                    expectedHashSHA256: nil,
                    actualHashSHA256: nil,
                    copyDurationMS: 0,
                    verifyDurationMS: 0
                ))
            }

            let bufferCount = buffer.count
            let bytesRead: Int = buffer.withUnsafeMutableBytes { mutableBytes in
                guard let baseAddress = mutableBytes.baseAddress else {
                    return -1
                }
                return read(fd, baseAddress, bufferCount)
            }
            if bytesRead < 0 {
                if errno == EINTR {
                    continue
                }
                throw SingleFileError(failure: FileFailure(
                    relativePath: job.relativePath,
                    sourcePath: job.sourcePath,
                    stagingPath: job.stagingPath,
                    finalPath: job.finalPath,
                    phase: .verify,
                    message: "Read-back read failed: \(lastErrnoMessage())",
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
            onVerifyProgress?(job, totalBytes)
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
