import Foundation

/// Identifies whether a cached snapshot still matches the file it was
/// resolved from. Size + mtime are already available on every scanned
/// candidate, so validating a fingerprint costs no extra file I/O.
public struct CachedFileFingerprint: Equatable, Sendable {
    public let sizeBytes: Int64
    public let mtime: Date

    public init(sizeBytes: Int64, mtime: Date) {
        self.sizeBytes = sizeBytes
        self.mtime = mtime
    }
}

/// A previously-resolved file's metadata, keyed elsewhere by absolute path.
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
    /// is safely reusable. Videos are reusable only when a camera was
    /// resolved: `VideoMetadataFallbackResolver.requiresEmbeddedFallback`
    /// and `VideoEmbeddedBoxMetadataResolver.requiresTextScanFallback` both
    /// gate on `cameraMake == nil && cameraModel == nil` -- the one tier
    /// that differs between preview (`.structuredOnly`) and deep (`.full`)
    /// scans is categorically unreachable whenever a camera already
    /// resolved, so a known-camera snapshot from preview is guaranteed
    /// identical to what a deep scan of the same unchanged file would
    /// produce.
    func isReusable(for mediaType: MediaType) -> Bool {
        switch mediaType {
        case .photo:
            return true
        case .video:
            return videoMetadata?.cameraMake != nil || videoMetadata?.cameraModel != nil
        case .audio:
            return true
        }
    }
}

/// Consulted and populated by `SourceScanner.scan(...)` to avoid re-resolving
/// metadata for files already resolved by an earlier scan of the same file.
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
