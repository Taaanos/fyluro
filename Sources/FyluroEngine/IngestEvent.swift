import Foundation

public enum IngestEvent: Sendable {
    case sessionStarted(sessionID: String, receiptPath: String, receiptSink: String)
    case phaseChanged(IngestPhase)
    case scanProgress(
        filesChecked: Int,
        bytesChecked: Int64,
        candidates: Int,
        photos: Int,
        photoBytes: Int64,
        videos: Int,
        videoBytes: Int64,
        audios: Int,
        audioBytes: Int64,
        currentPath: String?
    )
    case scanCompleted(candidates: Int, photos: Int, photoBytes: Int64, videos: Int, videoBytes: Int64, audios: Int, audioBytes: Int64)
    case planCompleted(
        plannedStageAndCommit: Int,
        duplicatesSkipped: Int,
        conflictsRenamed: Int,
        bytesToCopy: Int64,
        directoriesToCreate: [String]
    )
    case fileCopyStarted(path: String, expectedBytes: Int64)
    case fileCopyProgress(path: String, bytesCopied: Int64, expectedBytes: Int64)
    case fileVerifyProgress(path: String, bytesVerified: Int64, expectedBytes: Int64)
    case fileVerified(path: String)
    case fileCommitted(path: String, finalPath: String)
    case duplicateSkipped(path: String)
    case receiptLineAppended(line: String)
    case errorRecorded(phase: IngestPhase, message: String, paths: [String])
    case finished(IngestSessionResult)
}

public struct IngestRunHandle: Sendable {
    public let events: AsyncStream<IngestEvent>
    public let completion: Task<IngestSessionResult, Error>
    private let session: IngestSession

    init(events: AsyncStream<IngestEvent>, completion: Task<IngestSessionResult, Error>, session: IngestSession) {
        self.events = events
        self.completion = completion
        self.session = session
    }

    public func cancel() {
        session.cancel()
    }
}
