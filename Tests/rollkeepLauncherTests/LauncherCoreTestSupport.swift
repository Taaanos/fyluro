import XCTest
@testable import rollkeepLauncher
@testable import RollKeepCore

struct StubLauncherSourceDefaulting: LauncherSourceDefaulting {
    let path: String?

    func suggestedSourcePath() -> String? {
        path
    }
}

struct StubLauncherDestinationDefaulting: LauncherDestinationDefaulting {
    let path: String?

    func suggestedDestinationPath() -> String? {
        path
    }
}

final class StubLauncherDestinationRemembering: LauncherDestinationRemembering {
    private let initialPath: String?
    private(set) var savedPaths: [String] = []

    init(initialPath: String?) {
        self.initialPath = initialPath
    }

    func loadLastDestinationPath() -> String? {
        initialPath
    }

    func saveLastDestinationPath(_ path: String) {
        savedPaths.append(path)
    }
}

final class StubLauncherPathSchemeRemembering: LauncherPathSchemeRemembering {
    private let initialConfiguration: LauncherPathSchemeConfiguration
    private(set) var savedConfigurations: [LauncherPathSchemeConfiguration] = []

    init(initialConfiguration: LauncherPathSchemeConfiguration) {
        self.initialConfiguration = initialConfiguration
    }

    func loadAppliedPathScheme() -> LauncherPathSchemeConfiguration {
        savedConfigurations.last ?? initialConfiguration
    }

    func saveAppliedPathScheme(_ configuration: LauncherPathSchemeConfiguration) {
        savedConfigurations.append(configuration)
    }
}

final class StubLauncherFinderOpening: LauncherFinderOpening {
    private(set) var revealedURLs: [[URL]] = []
    private(set) var openedDirectories: [String] = []

    func reveal(_ urls: [URL]) {
        revealedURLs.append(urls)
    }

    @discardableResult
    func openDirectory(_ url: URL) -> Bool {
        openedDirectories.append(url.path)
        return true
    }
}

final class StubLauncherSourceScanner: LauncherSourceScanning, @unchecked Sendable {
    let progressSnapshots: [ScanProgressSnapshot]
    let finalPreparation: IngestPreparation
    let pauseAfterProgress: TimeInterval
    private let lock = NSLock()
    private(set) var requestedModes: [SourceScanMode] = []

    init(
        progressSnapshots: [ScanProgressSnapshot],
        finalPreparation: IngestPreparation,
        pauseAfterProgress: TimeInterval
    ) {
        self.progressSnapshots = progressSnapshots
        self.finalPreparation = finalPreparation
        self.pauseAfterProgress = pauseAfterProgress
    }

    func scan(
        sourcePath: String,
        mode: SourceScanMode,
        metadataCache: (any SourceScanMetadataCaching)?,
        progress: (@Sendable (ScanProgressSnapshot) -> Void)?
    ) throws -> IngestPreparation {
        lock.lock()
        requestedModes.append(mode)
        lock.unlock()

        for snapshot in progressSnapshots {
            progress?(snapshot)
        }

        if pauseAfterProgress > 0 {
            Thread.sleep(forTimeInterval: pauseAfterProgress)
        }

        return finalPreparation
    }
}

@MainActor
func waitUntil(
    timeout: TimeInterval = 1.0,
    pollInterval: TimeInterval = 0.01,
    condition: () -> Bool
) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() {
            return true
        }
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(pollInterval))
    }
    return condition()
}

func makeScanProgressSnapshot(
    itemCount: Int,
    photoCount: Int,
    videoCount: Int,
    totalBytes: Int64,
    distribution: [CameraDistributionEntry]
) -> ScanProgressSnapshot {
    let mediaCount = photoCount + videoCount
    let photoShare = mediaCount > 0 ? (Int64(photoCount) * totalBytes) / Int64(mediaCount) : 0
    let videoShare = totalBytes - photoShare
    return ScanProgressSnapshot(
        itemCount: itemCount,
        filesChecked: itemCount,
        photoCount: photoCount,
        videoCount: videoCount,
        photoBytes: photoShare,
        videoBytes: videoShare,
        bytesChecked: totalBytes,
        totalBytes: totalBytes,
        currentRelativePath: "DCIM/100MEDIA/IMG_0001.JPG",
        cameraAssessment: makeCameraAssessment(distribution: distribution)
    )
}

func makeScanSummary(
    itemCount: Int,
    photoCount: Int,
    videoCount: Int,
    totalBytes: Int64,
    distribution: [CameraDistributionEntry],
    unsortedPhotoCount: Int = 0
) -> ScanSummary {
    var candidates: [MediaCandidate] = []
    for index in 0..<photoCount {
        let captureDateTime: Date? = index < unsortedPhotoCount
            ? nil
            : Date(timeIntervalSince1970: 1_700_000_100 + Double(index))
        let captureDateSource: PhotoCaptureDateSource = captureDateTime == nil ? .missing : .dateTimeOriginal
        candidates.append(MediaCandidate(
            absolutePath: "/source/DCIM/IMG_\(index).JPG",
            relativePath: "DCIM/IMG_\(index).JPG",
            mediaType: .photo,
            sizeBytes: 100,
            mtime: Date(timeIntervalSince1970: 1_700_000_000 + Double(index)),
            photoMetadata: PhotoMetadata(
                captureDateTime: captureDateTime,
                captureDateSource: captureDateSource,
                cameraMake: nil,
                cameraModel: nil,
                cameraSerial: nil
            )
        ))
    }

    for index in 0..<videoCount {
        candidates.append(MediaCandidate(
            absolutePath: "/source/PRIVATE/VID_\(index).MP4",
            relativePath: "PRIVATE/VID_\(index).MP4",
            mediaType: .video,
            sizeBytes: 100,
            mtime: Date(timeIntervalSince1970: 1_700_000_500 + Double(index)),
            videoMetadata: VideoMetadata(
                captureDateTime: Date(timeIntervalSince1970: 1_700_000_600 + Double(index)),
                captureDateSource: .creationTime,
                usedFallback: false
            )
        ))
    }

    XCTAssertEqual(candidates.count, itemCount)

    return ScanSummary(
        candidates: candidates,
        photoCount: photoCount,
        videoCount: videoCount,
        photoBytes: Int64(photoCount) * 100,
        videoBytes: totalBytes - (Int64(photoCount) * 100),
        filesInTypicalLocations: itemCount,
        filesOutsideTypicalLocations: 0,
        errors: [],
        cameraAssessment: makeCameraAssessment(distribution: distribution)
    )
}

func makeDatedScanSummary(dates: [Date]) -> ScanSummary {
    let candidates = dates.enumerated().map { index, date in
        MediaCandidate(
            absolutePath: "/source/DCIM/IMG_\(index).JPG",
            relativePath: "DCIM/IMG_\(index).JPG",
            mediaType: .photo,
            sizeBytes: 100,
            mtime: date,
            photoMetadata: PhotoMetadata(
                captureDateTime: date,
                captureDateSource: .dateTimeOriginal,
                cameraMake: nil,
                cameraModel: nil,
                cameraSerial: nil
            )
        )
    }

    return ScanSummary(
        candidates: candidates,
        photoCount: candidates.count,
        videoCount: 0,
        photoBytes: Int64(candidates.count) * 100,
        videoBytes: 0,
        filesInTypicalLocations: candidates.count,
        filesOutsideTypicalLocations: 0,
        errors: []
    )
}

func makeDate(year: Int, month: Int, day: Int, hour: Int = 12) -> Date {
    var components = DateComponents()
    components.year = year
    components.month = month
    components.day = day
    components.hour = hour
    return Calendar.current.date(from: components)!
}

func makeIngestPreparation(summary: ScanSummary) -> IngestPreparation {
    var labelsInOrder: [String] = []
    labelsInOrder.reserveCapacity(summary.candidates.count)
    for entry in summary.cameraAssessment.distribution {
        labelsInOrder.append(contentsOf: Array(repeating: entry.cameraLabel, count: entry.fileCount))
    }

    var cameraInferenceByPath: [String: CameraInference] = [:]
    for (index, candidate) in summary.candidates.enumerated() {
        let label = index < labelsInOrder.count ? labelsInOrder[index] : CameraLabeler.unknownLabel
        cameraInferenceByPath[candidate.absolutePath] = CameraInference(
            cameraLabel: label,
            make: nil,
            model: nil,
            serial: nil
        )
    }

    return IngestPreparation(
        scanSummary: summary,
        cameraInferenceByPath: cameraInferenceByPath,
        plan: nil
    )
}

func makeCameraAssessment(distribution: [CameraDistributionEntry]) -> CameraCardAssessment {
    let knownDistribution = distribution.filter { $0.cameraLabel != CameraLabeler.unknownLabel }
    return CameraCardAssessment(
        totalCandidates: distribution.map(\.fileCount).reduce(0, +),
        knownCameraFileCount: knownDistribution.map(\.fileCount).reduce(0, +),
        unknownCameraFileCount: distribution.first(where: { $0.cameraLabel == CameraLabeler.unknownLabel })?.fileCount ?? 0,
        distribution: distribution
    )
}
