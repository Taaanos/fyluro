import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public enum IngestPhase: String, CaseIterable, Sendable {
    case scan
    case plan
    case copy
    case verify
    case commit
    case finalize
}

struct ReceiptSink {
    enum Kind: String {
        case destination
        case localFallback
    }

    let kind: Kind
    let path: String
}

enum ReceiptWriterError: Error {
    case noWritableReceiptPath(destinationError: Error, fallbackError: Error)
    case encodeFailed
    case openFailed(path: String, errnoCode: Int32)
    case appendFailed(path: String, errnoCode: Int32)
}

enum ReceiptEventType: String {
    case sessionStarted = "SESSION_STARTED"
    case scanProgress = "SCAN_PROGRESS"
    case scanSummary = "SCAN_SUMMARY"
    case scanWarning = "SCAN_WARNING"
    case scanFileList = "SCAN_FILE_LIST"
    case cameraLabelDetected = "CAMERA_LABEL_DETECTED"
    case planComputed = "PLAN_COMPUTED"
    case dirCreated = "DIR_CREATED"
    case fileCopyStarted = "FILE_COPY_STARTED"
    case fileCopied = "FILE_COPIED"
    case fileVerifyStarted = "FILE_VERIFY_STARTED"
    case fileVerified = "FILE_VERIFIED"
    case fileCommitStarted = "FILE_COMMIT_STARTED"
    case fileCommitted = "FILE_COMMITTED"
    case duplicateSkipped = "DUPLICATE_SKIPPED"
    case conflictRenamed = "CONFLICT_RENAMED"
    case videoMetadataFallbackUsed = "VIDEO_METADATA_FALLBACK_USED"
    case receiptPDFWritten = "RECEIPT_PDF_WRITTEN"
    case error = "ERROR"
    case summary = "SUMMARY"
    case sessionFinished = "SESSION_FINISHED"
}

struct ReceiptSinkTransition {
    let from: ReceiptSink
    let to: ReceiptSink
    let timestamp: String
    let reason: String

    var payload: [String: Any] {
        [
            "from_kind": from.kind.rawValue,
            "from_path": from.path,
            "to_kind": to.kind.rawValue,
            "to_path": to.path,
            "timestamp": timestamp,
            "reason": reason,
        ]
    }
}

enum ReceiptFlushPolicy {
    case immediate
    case periodic
    case deferred
    case fullSync
}

final class ReceiptWriter {
    static let defaultPeriodicFlushInterval: TimeInterval = 2.0

    let sessionID: String

    private(set) var sink: ReceiptSink
    private(set) var sinkTransitions: [ReceiptSinkTransition] = []

    private let lock = NSLock()
    private let fileManager: FileManager
    private let destinationPath: String
    private let fallbackPath: String
    private let appenderFactory: (String, FileManager) throws -> ReceiptAppending
    private let periodicFlushInterval: TimeInterval
    private let nowProvider: () -> Date
    private let isoFormatter = ISO8601DateFormatter()
    private let injectedDestinationAppendFailureAtEventIndex: Int?
    private var appender: ReceiptAppending
    private var eventIndex = 0
    private var didInjectDestinationAppendFailure = false
    private var sinkPathHistory: [String] = []
    private var unflushedLines: [Data] = []
    private var lastFlushAt: Date

    var onLineAppended: ((String) -> Void)?

    init(
        destRoot: URL,
        sessionID: String,
        fileManager: FileManager = .default,
        injectedDestinationAppendFailureAtEventIndex: Int? = nil,
        periodicFlushInterval: TimeInterval = ReceiptWriter.defaultPeriodicFlushInterval,
        nowProvider: @escaping () -> Date = Date.init,
        appenderFactory: @escaping (String, FileManager) throws -> ReceiptAppending = { path, fileManager in
            try AppendOnlyLineAppender(path: path, fileManager: fileManager)
        }
    ) throws {
        self.sessionID = sessionID
        self.fileManager = fileManager
        self.periodicFlushInterval = periodicFlushInterval
        self.nowProvider = nowProvider
        self.lastFlushAt = nowProvider()
        self.appenderFactory = appenderFactory
        self.injectedDestinationAppendFailureAtEventIndex = injectedDestinationAppendFailureAtEventIndex

        let destinationDir = destRoot.appendingPathComponent("_ingest_receipts", isDirectory: true)
        self.destinationPath = destinationDir
            .appendingPathComponent("\(sessionID).ndjson", isDirectory: false)
            .path
        let fallbackDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("fyluro", isDirectory: true)
            .appendingPathComponent("_ingest_receipts", isDirectory: true)
        self.fallbackPath = fallbackDir
            .appendingPathComponent("\(sessionID).ndjson", isDirectory: false)
            .path

        do {
            self.appender = try appenderFactory(destinationPath, fileManager)
            self.sink = ReceiptSink(kind: .destination, path: destinationPath)
            self.sinkPathHistory = [destinationPath]
            return
        } catch {
            let destinationError = error

            do {
                self.appender = try appenderFactory(fallbackPath, fileManager)
                self.sink = ReceiptSink(kind: .localFallback, path: fallbackPath)
                self.sinkPathHistory = [fallbackPath]
                return
            } catch {
                throw ReceiptWriterError.noWritableReceiptPath(destinationError: destinationError, fallbackError: error)
            }
        }
    }

    var receiptPaths: [ReceiptSink] {
        lock.lock()
        defer { lock.unlock() }
        return sinkPathHistory.map { path in
            let kind: ReceiptSink.Kind = path == destinationPath ? .destination : .localFallback
            return ReceiptSink(kind: kind, path: path)
        }
    }

    func resumeHook() -> [String: Any] {
        lock.lock()
        let currentEventIndex = eventIndex
        let currentSink = sink
        let paths = sinkPathHistory.map { path in
            let kind: ReceiptSink.Kind = path == destinationPath ? .destination : .localFallback
            return ReceiptSink(kind: kind, path: path)
        }
        lock.unlock()

        return [
            "session_id": sessionID,
            "last_event_index": currentEventIndex,
            "receipt_paths": paths.map { ["kind": $0.kind.rawValue, "path": $0.path] },
            "active_receipt_path": currentSink.path,
            "active_receipt_sink": currentSink.kind.rawValue,
        ]
    }

    func append(
        eventType: ReceiptEventType,
        phase: IngestPhase,
        data: [String: Any],
        flushPolicy: ReceiptFlushPolicy = .immediate
    ) throws {
        let lineObserver: ((String) -> Void)?
        let lineData: Data

        lock.lock()
        do {
            let now = nowProvider()
            let nextEventIndex = eventIndex + 1
            let payload: [String: Any] = [
                "session_id": sessionID,
                "event_index": nextEventIndex,
                "timestamp": isoFormatter.string(from: now),
                "event_type": eventType.rawValue,
                "phase": phase.rawValue,
                "data": data,
            ]

            guard JSONSerialization.isValidJSONObject(payload),
                  var encoded = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else {
                lock.unlock()
                throw ReceiptWriterError.encodeFailed
            }
            encoded.append(0x0A)
            lineData = encoded

            let shouldFlush: Bool
            let useFullSync: Bool
            switch flushPolicy {
            case .immediate:
                shouldFlush = true
                useFullSync = false
            case .periodic:
                shouldFlush = now.timeIntervalSince(lastFlushAt) >= periodicFlushInterval
                useFullSync = false
            case .deferred:
                shouldFlush = false
                useFullSync = false
            case .fullSync:
                shouldFlush = true
                useFullSync = true
            }

            let pendingStartCount = unflushedLines.count
            do {
                try injectDestinationAppendFailureIfNeeded(nextEventIndex: nextEventIndex)
                try appender.append(lineData)
                unflushedLines.append(lineData)
                if shouldFlush {
                    try appender.flush(fullSync: useFullSync)
                    unflushedLines.removeAll(keepingCapacity: true)
                    lastFlushAt = now
                }
                eventIndex = nextEventIndex
            } catch {
                guard sink.kind == .destination else {
                    lock.unlock()
                    throw error
                }
                if unflushedLines.count == pendingStartCount {
                    unflushedLines.append(lineData)
                }
                try switchToFallbackAndReplayUnflushed(
                    reason: "destination_receipt_append_failed",
                    fullSync: useFullSync,
                    now: now
                )
                eventIndex = nextEventIndex
            }

            lineObserver = onLineAppended
            lock.unlock()
        } catch {
            lock.unlock()
            throw error
        }

        if let lineObserver {
            var lineForObserver = lineData
            lineForObserver.removeLast() // strip trailing newline
            if let line = String(data: lineForObserver, encoding: .utf8) {
                lineObserver(line)
            }
        }
    }

    func flush(fullSync: Bool = false) throws {
        lock.lock()
        defer { lock.unlock() }

        guard !unflushedLines.isEmpty || fullSync else {
            return
        }

        let now = nowProvider()
        do {
            try appender.flush(fullSync: fullSync)
            unflushedLines.removeAll(keepingCapacity: true)
            lastFlushAt = now
        } catch {
            guard sink.kind == .destination else {
                throw error
            }
            try switchToFallbackAndReplayUnflushed(
                reason: "destination_receipt_append_failed",
                fullSync: fullSync,
                now: now
            )
        }
    }

    private func injectDestinationAppendFailureIfNeeded(nextEventIndex: Int) throws {
        guard sink.kind == .destination else {
            return
        }
        guard let targetIndex = injectedDestinationAppendFailureAtEventIndex,
              !didInjectDestinationAppendFailure,
              nextEventIndex >= targetIndex else {
            return
        }

        didInjectDestinationAppendFailure = true
        throw ReceiptWriterError.appendFailed(path: sink.path, errnoCode: EIO)
    }

    private func switchToFallbackAndReplayUnflushed(
        reason: String,
        fullSync: Bool,
        now: Date
    ) throws {
        try switchToFallback(reason: reason, now: now)
        for pendingLine in unflushedLines {
            try appender.append(pendingLine)
        }
        try appender.flush(fullSync: fullSync)
        unflushedLines.removeAll(keepingCapacity: true)
        lastFlushAt = now
    }

    private func switchToFallback(reason: String, now: Date) throws {
        guard sink.kind != .localFallback else {
            return
        }

        let previousSink = sink
        let fallbackAppender = try appenderFactory(fallbackPath, fileManager)
        self.appender = fallbackAppender
        self.sink = ReceiptSink(kind: .localFallback, path: fallbackPath)
        sinkTransitions.append(ReceiptSinkTransition(
            from: previousSink,
            to: sink,
            timestamp: isoFormatter.string(from: now),
            reason: reason
        ))

        if !sinkPathHistory.contains(fallbackPath) {
            sinkPathHistory.append(fallbackPath)
        }
    }
}

protocol ReceiptAppending {
    func append(_ lineData: Data) throws
    func flush(fullSync: Bool) throws
}

private final class AppendOnlyLineAppender: ReceiptAppending {
    private let path: String
    private let fd: Int32
    private var hasUnflushedWrites = false

    init(path: String, fileManager: FileManager) throws {
        self.path = path

        let fileURL = URL(fileURLWithPath: path, isDirectory: false)
        let dirURL = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: dirURL, withIntermediateDirectories: true)

        if !fileManager.fileExists(atPath: path),
           !fileManager.createFile(atPath: path, contents: nil) {
            throw ReceiptWriterError.openFailed(path: path, errnoCode: errno)
        }

        let descriptor = open(path, O_WRONLY | O_APPEND)
        if descriptor == -1 {
            throw ReceiptWriterError.openFailed(path: path, errnoCode: errno)
        }
        self.fd = descriptor
    }

    deinit {
        if hasUnflushedWrites {
            _ = fsync(fd)
        }
        _ = close(fd)
    }

    func append(_ lineData: Data) throws {
        try lineData.withUnsafeBytes { rawBuffer in
            guard var pointer = rawBuffer.baseAddress else {
                return
            }

            var remainingBytes = rawBuffer.count
            while remainingBytes > 0 {
                let bytesWritten = write(fd, pointer, remainingBytes)
                if bytesWritten < 0 {
                    if errno == EINTR {
                        continue
                    }
                    throw ReceiptWriterError.appendFailed(path: path, errnoCode: errno)
                }

                remainingBytes -= bytesWritten
                pointer = pointer.advanced(by: bytesWritten)
            }
        }
        hasUnflushedWrites = true
    }

    func flush(fullSync: Bool) throws {
        #if canImport(Darwin)
        if fullSync {
            if fcntl(fd, F_FULLFSYNC) == 0 {
                hasUnflushedWrites = false
                return
            }
            if errno != ENOTSUP && errno != EINVAL && errno != ENOTTY {
                throw ReceiptWriterError.appendFailed(path: path, errnoCode: errno)
            }
        }
        #endif

        if fsync(fd) != 0 {
            throw ReceiptWriterError.appendFailed(path: path, errnoCode: errno)
        }
        hasUnflushedWrites = false
    }
}
