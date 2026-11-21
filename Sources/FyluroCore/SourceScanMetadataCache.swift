import Foundation

public struct CachedFileFingerprint: Equatable, Sendable {
    public let sizeBytes: Int64
    public let mtime: Date

    public init(sizeBytes: Int64, mtime: Date) {
        self.sizeBytes = sizeBytes
        self.mtime = mtime
    }
}

public struct CachedFileMetadataSnapshot: Sendable {
    public let fingerprint: CachedFileFingerprint
    public let photoMetadata: PhotoMetadata?
    public let videoMetadata: VideoMetadata?
    public let audioMetadata: AudioMetadata?

    public init(
        fingerprint: CachedFileFingerprint,
        photoMetadata: PhotoMetadata?,
        videoMetadata: VideoMetadata?,
        audioMetadata: AudioMetadata? = nil
    ) {
        self.fingerprint = fingerprint
        self.photoMetadata = photoMetadata
        self.videoMetadata = videoMetadata
        self.audioMetadata = audioMetadata
    }

    /// Photos have no mode-dependent extraction tier, so any photo snapshot
    /// is safely reusable.
    ///
    /// Videos: reusable only when BOTH cameraMake and cameraModel are
    /// resolved -- not "at least one".
    /// `VideoMetadataFallbackResolver.requiresEmbeddedFallback` now gates on
    /// `make == nil || model == nil` (widened from `&&` so a file with only
    /// one field missing still reaches the vendor decoders for the other),
    /// so tier 3 -- and specifically its mode-dependent inner step, the
    /// blind text scan, which runs only under `.full` -- is reachable
    /// whenever *either* field is still nil, not only when both are. The
    /// merge at every tier always prefers an already-non-nil value
    /// (`primary.field ?? fallback.field`), so a `.structuredOnly` preview
    /// scan is derived entirely from mode-independent sources (AVFoundation,
    /// sidecar, box-walk decoders -- never the text scan, which is an
    /// unconditional no-op in that mode) and can only ever be *missing*
    /// something a `.full` deep scan might still find, never have found
    /// something extra. So a preview snapshot is guaranteed identical to
    /// what a deep scan would produce only when neither field is still
    /// nil -- any remaining nil field is a real chance the deep scan's
    /// text-scan step could resolve that must not be skipped by reuse.
    func isReusable(for mediaType: MediaType) -> Bool {
        switch mediaType {
        case .photo:
            return true
        case .video:
            return videoMetadata?.cameraMake != nil && videoMetadata?.cameraModel != nil
        case .audio:
            return true
        }
    }
}

public protocol SourceScanMetadataCaching: Sendable {
    func priorSnapshot(forPath path: String, fingerprint: CachedFileFingerprint) -> CachedFileMetadataSnapshot?
    func record(_ snapshot: CachedFileMetadataSnapshot, forPath path: String)
}

/// In-memory only, never persisted, scoped to a single scan dispatch
/// (seconds to minutes). This is not the ledger design
/// `docs/adr/0001-no-verification-opt-out.md` rejects: it never crosses a
/// process/session boundary and never gates copy/hash/verify/commit -- only
/// which tier of *source* metadata extraction runs for one file within one
/// ingest attempt. A wrong entry (caught by the fingerprint check below in
/// the vast majority of cases) can at worst misfile a destination folder,
/// not silently corrupt or skip verification of copied bytes.
public final class InMemorySourceScanMetadataCache: SourceScanMetadataCaching, @unchecked Sendable {
    private let lock = NSLock()
    private var snapshotsByPath: [String: CachedFileMetadataSnapshot] = [:]

    public init() {}

    public func priorSnapshot(forPath path: String, fingerprint: CachedFileFingerprint) -> CachedFileMetadataSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        guard let snapshot = snapshotsByPath[path], snapshot.fingerprint == fingerprint else {
            return nil
        }
        return snapshot
    }

    public func record(_ snapshot: CachedFileMetadataSnapshot, forPath path: String) {
        lock.lock()
        defer { lock.unlock() }
        snapshotsByPath[path] = snapshot
    }
}
