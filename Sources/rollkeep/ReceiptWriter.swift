import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

enum IngestPhase: String {
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
    case scanSummary = "SCAN_SUMMARY"
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
    case receiptMarkdownWritten = "RECEIPT_MARKDOWN_WRITTEN"
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

final class ReceiptWriter {
    let sessionID: String

    private(set) var sink: ReceiptSink
    private(set) var sinkTransitions: [ReceiptSinkTransition] = []

    private let fileManager: FileManager
    private let destinationPath: String
    private let fallbackPath: String
    private let isoFormatter = ISO8601DateFormatter()
    private var appender: AppendOnlyLineAppender
    private var eventIndex = 0
    private var sinkPathHistory: [String] = []

    init(destRoot: URL, sessionID: String, fileManager: FileManager = .default) throws {
        self.sessionID = sessionID
        self.fileManager = fileManager

        let destinationDir = destRoot.appendingPathComponent("_ingest_receipts", isDirectory: true)
        self.destinationPath = destinationDir
            .appendingPathComponent("\(sessionID).ndjson", isDirectory: false)
            .path
        let fallbackDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("rollkeep", isDirectory: true)
            .appendingPathComponent("_ingest_receipts", isDirectory: true)
        self.fallbackPath = fallbackDir
            .appendingPathComponent("\(sessionID).ndjson", isDirectory: false)
            .path

        do {
            self.appender = try AppendOnlyLineAppender(path: destinationPath, fileManager: fileManager)
            self.sink = ReceiptSink(kind: .destination, path: destinationPath)
            self.sinkPathHistory = [destinationPath]
            return
        } catch {
            let destinationError = error

            do {
                self.appender = try AppendOnlyLineAppender(path: fallbackPath, fileManager: fileManager)
                self.sink = ReceiptSink(kind: .localFallback, path: fallbackPath)
                self.sinkPathHistory = [fallbackPath]
                return
            } catch {
                throw ReceiptWriterError.noWritableReceiptPath(destinationError: destinationError, fallbackError: error)
            }
        }
    }

    var receiptPaths: [ReceiptSink] {
        sinkPathHistory.map { path in
            let kind: ReceiptSink.Kind = path == destinationPath ? .destination : .localFallback
            return ReceiptSink(kind: kind, path: path)
        }
    }

    func resumeHook() -> [String: Any] {
        [
            "session_id": sessionID,
            "last_event_index": eventIndex,
            "receipt_paths": receiptPaths.map { ["kind": $0.kind.rawValue, "path": $0.path] },
            "active_receipt_path": sink.path,
            "active_receipt_sink": sink.kind.rawValue,
        ]
    }

    func append(eventType: ReceiptEventType, phase: IngestPhase, data: [String: Any]) throws {
        let nextEventIndex = eventIndex + 1
        let payload: [String: Any] = [
            "session_id": sessionID,
            "event_index": nextEventIndex,
            "timestamp": isoFormatter.string(from: Date()),
            "event_type": eventType.rawValue,
            "phase": phase.rawValue,
            "data": data,
        ]

        guard JSONSerialization.isValidJSONObject(payload),
              var lineData = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else {
            throw ReceiptWriterError.encodeFailed
        }
        lineData.append(0x0A)

        do {
            try appender.append(lineData)
            eventIndex = nextEventIndex
        } catch {
            guard sink.kind == .destination else {
                throw error
            }
            try switchToFallback(reason: "destination_receipt_append_failed")
            try appender.append(lineData)
            eventIndex = nextEventIndex
        }
    }

    private func switchToFallback(reason: String) throws {
        guard sink.kind != .localFallback else {
            return
        }

        let previousSink = sink
        let fallbackAppender = try AppendOnlyLineAppender(path: fallbackPath, fileManager: fileManager)
        self.appender = fallbackAppender
        self.sink = ReceiptSink(kind: .localFallback, path: fallbackPath)
        sinkTransitions.append(ReceiptSinkTransition(
            from: previousSink,
            to: sink,
            timestamp: isoFormatter.string(from: Date()),
            reason: reason
        ))

        if !sinkPathHistory.contains(fallbackPath) {
            sinkPathHistory.append(fallbackPath)
        }
    }
}

private final class AppendOnlyLineAppender {
    private let path: String
    private let fd: Int32

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

        if fsync(fd) != 0 {
            throw ReceiptWriterError.appendFailed(path: path, errnoCode: errno)
        }
    }
}
