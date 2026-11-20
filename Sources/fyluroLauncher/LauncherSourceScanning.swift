import Foundation
import FyluroCore

struct LauncherSourceScopeSummary: Equatable {
    let itemCount: Int
    let photoCount: Int
    let videoCount: Int
    let audioCount: Int
    let totalBytes: Int64
    let unsortedCount: Int
    let errorCount: Int
    let warningCount: Int
    let cameraEntries: [LauncherSourceCameraSummary]
    // Stored as two Dates rather than a tuple: Equatable synthesis can't
    // handle a stored tuple-typed property.
    private let captureDateRangeStart: Date?
    private let captureDateRangeEnd: Date?

    init(
        itemCount: Int,
        photoCount: Int,
        videoCount: Int,
        audioCount: Int = 0,
        totalBytes: Int64,
        unsortedCount: Int = 0,
        errorCount: Int = 0,
        warningCount: Int = 0,
        cameraEntries: [LauncherSourceCameraSummary] = [],
        captureDateRangeStart: Date? = nil,
        captureDateRangeEnd: Date? = nil
    ) {
        self.itemCount = itemCount
        self.photoCount = photoCount
        self.videoCount = videoCount
        self.audioCount = audioCount
        self.totalBytes = totalBytes
        self.unsortedCount = max(0, unsortedCount)
        self.errorCount = max(0, errorCount)
        self.warningCount = max(0, warningCount)
        self.cameraEntries = cameraEntries
        self.captureDateRangeStart = captureDateRangeStart
        self.captureDateRangeEnd = captureDateRangeEnd
    }

    // ScanProgressSnapshot (live/in-progress scanning) carries no per-candidate
    // array, so the capture date range stays nil, and unsortedCount/errorCount/
    // warningCount stay 0, until the scan reaches .ready.
    init(snapshot: ScanProgressSnapshot) {
        self.init(
            itemCount: snapshot.itemCount,
            photoCount: snapshot.photoCount,
            videoCount: snapshot.videoCount,
            audioCount: snapshot.audioCount,
            totalBytes: snapshot.totalBytes,
            unsortedCount: 0,
            cameraEntries: Self.cameraEntries(from: snapshot.cameraAssessment)
        )
    }

    init(summary: ScanSummary) {
        let dateRange = Self.dateRange(from: summary.candidates)
        self.init(
            itemCount: summary.candidates.count,
            photoCount: summary.photoCount,
            videoCount: summary.videoCount,
            audioCount: summary.audioCount,
            totalBytes: summary.photoBytes + summary.videoBytes + summary.audioBytes,
            unsortedCount: Self.unsortedCount(from: summary.candidates),
            errorCount: summary.errors.count,
            warningCount: summary.warnings.count,
            cameraEntries: Self.cameraEntries(from: summary.cameraAssessment),
            captureDateRangeStart: dateRange?.start,
            captureDateRangeEnd: dateRange?.end
        )
    }

    init(preparation: IngestPreparation) {
        let dateRange = Self.dateRange(from: preparation.scanSummary.candidates)
        self.init(
            itemCount: preparation.scanSummary.candidates.count,
            photoCount: preparation.scanSummary.photoCount,
            videoCount: preparation.scanSummary.videoCount,
            audioCount: preparation.scanSummary.audioCount,
            totalBytes: preparation.scanSummary.photoBytes + preparation.scanSummary.videoBytes + preparation.scanSummary.audioBytes,
            unsortedCount: Self.unsortedCount(from: preparation.scanSummary.candidates),
            errorCount: preparation.scanSummary.errors.count,
            warningCount: preparation.scanSummary.warnings.count,
            cameraEntries: Self.cameraEntries(from: preparation.cameraAssessment),
            captureDateRangeStart: dateRange?.start,
            captureDateRangeEnd: dateRange?.end
        )
    }

    var captureDateRange: (start: Date, end: Date)? {
        guard let captureDateRangeStart, let captureDateRangeEnd else {
            return nil
        }
        return (captureDateRangeStart, captureDateRangeEnd)
    }

    var mediaDescription: String {
        var kinds: [String] = []
        if photoCount > 0 { kinds.append("photos") }
        if videoCount > 0 { kinds.append("videos") }
        if audioCount > 0 { kinds.append("audio") }

        guard let first = kinds.first else {
            return "No media found"
        }
        let capitalizedFirst = first.prefix(1).uppercased() + first.dropFirst()
        guard kinds.count > 1 else {
            return capitalizedFirst
        }
        return capitalizedFirst + " and " + kinds.dropFirst().joined(separator: " and ")
    }

    var detectedCameraCount: Int {
        cameraEntries.filter { !$0.isUnknown }.count
    }

    var unsortedWarningText: String? {
        guard unsortedCount > 0 else {
            return nil
        }

        let noun = unsortedCount == 1 ? "item" : "items"
        return "\(unsortedCount) \(noun) will be placed in _unsorted because capture date metadata is missing."
    }

    var scanErrorText: String? {
        guard errorCount > 0 else {
            return nil
        }

        let noun = errorCount == 1 ? "file" : "files"
        return "\(errorCount) \(noun) couldn't be read and will be skipped."
    }

    var scanWarningText: String? {
        guard warningCount > 0 else {
            return nil
        }

        let noun = warningCount == 1 ? "file" : "files"
        return "\(warningCount) \(noun) will be skipped (large or unsupported files)."
    }

    private static func cameraEntries(from assessment: CameraCardAssessment) -> [LauncherSourceCameraSummary] {
        assessment.distribution.map { entry in
            LauncherSourceCameraSummary(
                label: entry.cameraLabel,
                fileCount: entry.fileCount,
                rawModelCode: entry.rawModelCode
            )
        }
    }

    private static func unsortedCount(from candidates: [MediaCandidate]) -> Int {
        candidates.reduce(0) { partial, candidate in
            let hasCaptureDate: Bool
            switch candidate.mediaType {
            case .photo:
                hasCaptureDate = candidate.photoMetadata?.captureDateTime != nil
            case .video:
                hasCaptureDate = candidate.videoMetadata?.captureDateTime != nil
            case .audio:
                hasCaptureDate = candidate.audioMetadata?.captureDateTime != nil
            }

            return partial + (hasCaptureDate ? 0 : 1)
        }
    }

    private static func dateRange(from candidates: [MediaCandidate]) -> (start: Date, end: Date)? {
        let dates = candidates.compactMap { candidate -> Date? in
            switch candidate.mediaType {
            case .photo:
                return candidate.photoMetadata?.captureDateTime
            case .video:
                return candidate.videoMetadata?.captureDateTime
            case .audio:
                return candidate.audioMetadata?.captureDateTime
            }
        }

        guard let start = dates.min(), let end = dates.max() else {
            return nil
        }
        return (start: start, end: end)
    }
}

struct LauncherSourceCameraSummary: Equatable, Identifiable {
    let label: String
    let fileCount: Int
    let rawModelCode: String?

    init(label: String, fileCount: Int, rawModelCode: String? = nil) {
        self.label = label
        self.fileCount = fileCount
        self.rawModelCode = rawModelCode
    }

    var id: String { label }

    var isUnknown: Bool {
        label == CameraLabeler.unknownLabel
    }

    var displayLabel: String {
        isUnknown ? "Unknown camera" : label
    }
}

protocol LauncherSourceScanning: Sendable {
    func scan(
        sourcePath: String,
        mode: SourceScanMode,
        metadataCache: (any SourceScanMetadataCaching)?,
        progress: (@Sendable (ScanProgressSnapshot) -> Void)?
    ) throws -> IngestPreparation
}

struct LauncherSharedSourceScanner: LauncherSourceScanning {
    var cameraLabelsPreference: any LauncherCameraLabelsPreferring = LauncherCameraLabelsPreference()

    func scan(
        sourcePath: String,
        mode: SourceScanMode = .deep,
        metadataCache: (any SourceScanMetadataCaching)? = nil,
        progress: (@Sendable (ScanProgressSnapshot) -> Void)? = nil
    ) throws -> IngestPreparation {
        let cameraLabeler = CameraLabeler.forRun(usingUserCatalog: cameraLabelsPreference.isEnabled)
        return try IngestPreparationService(
            sourceScanner: SourceScanner(cameraLabeler: cameraLabeler),
            cameraLabeler: cameraLabeler
        ).scan(
            sourceRoot: URL(fileURLWithPath: sourcePath, isDirectory: true),
            mode: mode,
            metadataCache: metadataCache,
            progress: progress
        )
    }
}

