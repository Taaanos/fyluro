import Foundation

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
}

final class ReceiptWriter {
    let sessionID: String
    let sink: ReceiptSink

    private let fileHandle: FileHandle
    private let isoFormatter = ISO8601DateFormatter()

    init(destRoot: URL, sessionID: String, fileManager: FileManager = .default) throws {
        self.sessionID = sessionID

        do {
            let destDir = destRoot.appendingPathComponent("_ingest_receipts", isDirectory: true)
            try fileManager.createDirectory(at: destDir, withIntermediateDirectories: true)

            let fileURL = destDir.appendingPathComponent("\(sessionID).ndjson", isDirectory: false)
            if !fileManager.fileExists(atPath: fileURL.path) {
                fileManager.createFile(atPath: fileURL.path, contents: nil)
            }

            self.fileHandle = try FileHandle(forWritingTo: fileURL)
            self.fileHandle.seekToEndOfFile()
            self.sink = ReceiptSink(kind: .destination, path: fileURL.path)
            return
        } catch {
            let destinationError = error

            do {
                let fallbackRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                    .appendingPathComponent("rollkeep", isDirectory: true)
                    .appendingPathComponent("_ingest_receipts", isDirectory: true)

                try fileManager.createDirectory(at: fallbackRoot, withIntermediateDirectories: true)

                let fileURL = fallbackRoot.appendingPathComponent("\(sessionID).ndjson", isDirectory: false)
                if !fileManager.fileExists(atPath: fileURL.path) {
                    fileManager.createFile(atPath: fileURL.path, contents: nil)
                }

                self.fileHandle = try FileHandle(forWritingTo: fileURL)
                self.fileHandle.seekToEndOfFile()
                self.sink = ReceiptSink(kind: .localFallback, path: fileURL.path)
                return
            } catch {
                throw ReceiptWriterError.noWritableReceiptPath(destinationError: destinationError, fallbackError: error)
            }
        }
    }

    deinit {
        fileHandle.closeFile()
    }

    func append(eventType: String, phase: IngestPhase, data: [String: Any]) throws {
        var payload: [String: Any] = [
            "session_id": sessionID,
            "timestamp": isoFormatter.string(from: Date()),
            "event_type": eventType,
            "phase": phase.rawValue,
            "data": data,
        ]

        if let jsonData = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) {
            payload.removeAll()
            fileHandle.write(jsonData)
            fileHandle.write(Data([0x0A]))
            fileHandle.synchronizeFile()
            return
        }

        throw ReceiptWriterError.encodeFailed
    }
}
