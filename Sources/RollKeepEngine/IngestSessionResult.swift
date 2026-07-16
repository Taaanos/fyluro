import Foundation

public struct IngestPhaseTiming: Sendable {
    public let phase: IngestPhase
    public let milliseconds: Int

    public init(phase: IngestPhase, milliseconds: Int) {
        self.phase = phase
        self.milliseconds = milliseconds
    }
}

public struct IngestCounts: Sendable {
    public let candidates: Int
    public let photos: Int
    public let videos: Int
    public let audios: Int
    public let copied: Int
    public let verified: Int
    public let committed: Int
    public let duplicateNotCopied: Int
    public let conflictsRenamed: Int
    public let errors: Int

    public init(
        candidates: Int,
        photos: Int,
        videos: Int,
        audios: Int = 0,
        copied: Int,
        verified: Int,
        committed: Int,
        duplicateNotCopied: Int,
        conflictsRenamed: Int,
        errors: Int
    ) {
        self.candidates = candidates
        self.photos = photos
        self.videos = videos
        self.audios = audios
        self.copied = copied
        self.verified = verified
        self.committed = committed
        self.duplicateNotCopied = duplicateNotCopied
        self.conflictsRenamed = conflictsRenamed
        self.errors = errors
    }
}

/// Idempotency classification for a finished ingest session. Computed by the
/// engine (moved out of the CLI's summary renderer) so in-process consumers
/// such as the macOS app can read it directly.
public struct IngestIdempotency: Sendable {
    public let classification: String
    public let newFilesCommitted: Int
    public let duplicatesSkipped: Int

    public init(classification: String, newFilesCommitted: Int, duplicatesSkipped: Int) {
        self.classification = classification
        self.newFilesCommitted = newFilesCommitted
        self.duplicatesSkipped = duplicatesSkipped
    }

    init(finalStatus: String, dryRun: Bool, counts: IngestCounts) {
        let committed = max(counts.committed, 0)
        let duplicates = max(counts.duplicateNotCopied, 0)

        if finalStatus == "aborted" {
            self.init(classification: "unknown_due_to_failure", newFilesCommitted: committed, duplicatesSkipped: duplicates)
        } else if dryRun {
            self.init(classification: "dry_run_not_applicable", newFilesCommitted: committed, duplicatesSkipped: duplicates)
        } else if committed == 0, duplicates > 0 {
            self.init(classification: "idempotent_rerun", newFilesCommitted: 0, duplicatesSkipped: duplicates)
        } else {
            self.init(classification: "new_files_committed", newFilesCommitted: committed, duplicatesSkipped: duplicates)
        }
    }
}

/// The outcome of a full ingest session run. Presentation concerns (exit code,
/// human/JSON rendering) live in the CLI; this type is the engine's contract
/// with every consumer.
public struct IngestSessionResult: Sendable {
    public let sessionID: String
    public let finalStatus: String
    public let dryRun: Bool
    public let receiptPath: String
    public let receiptSink: String
    public let stagingSessionPath: String
    public let pdfSummaryPath: String?
    public let failurePhase: IngestPhase?
    public let failureReason: String?
    public let firstErrors: [String]
    public let phaseTimings: [IngestPhaseTiming]
    public let counts: IngestCounts
    public let idempotency: IngestIdempotency

    public init(
        sessionID: String,
        finalStatus: String,
        dryRun: Bool,
        receiptPath: String,
        receiptSink: String,
        stagingSessionPath: String,
        pdfSummaryPath: String?,
        failurePhase: IngestPhase?,
        failureReason: String?,
        firstErrors: [String],
        phaseTimings: [IngestPhaseTiming],
        counts: IngestCounts,
        idempotency: IngestIdempotency
    ) {
        self.sessionID = sessionID
        self.finalStatus = finalStatus
        self.dryRun = dryRun
        self.receiptPath = receiptPath
        self.receiptSink = receiptSink
        self.stagingSessionPath = stagingSessionPath
        self.pdfSummaryPath = pdfSummaryPath
        self.failurePhase = failurePhase
        self.failureReason = failureReason
        self.firstErrors = firstErrors
        self.phaseTimings = phaseTimings
        self.counts = counts
        self.idempotency = idempotency
    }
}

struct PhaseTimingTracker {
    private var millisecondsByPhase: [IngestPhase: Int] = [:]

    mutating func capture(_ phase: IngestPhase, startedAt: Date) {
        let elapsedMs = Int((Date().timeIntervalSince(startedAt) * 1_000).rounded())
        add(phase, milliseconds: max(0, elapsedMs))
    }

    mutating func add(_ phase: IngestPhase, milliseconds: Int) {
        millisecondsByPhase[phase, default: 0] += milliseconds
    }

    func value(for phase: IngestPhase) -> Int {
        millisecondsByPhase[phase] ?? 0
    }

    func allPhases() -> [IngestPhaseTiming] {
        IngestPhase.allCases.map { phase in
            IngestPhaseTiming(phase: phase, milliseconds: value(for: phase))
        }
    }
}
