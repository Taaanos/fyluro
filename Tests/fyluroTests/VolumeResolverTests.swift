import Foundation
import XCTest
@testable import fyluro

final class VolumeResolverTests: XCTestCase {
    private var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("fyluro-volume-resolver-\(UUID().uuidString.lowercased())", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
    }

    func testResolveRejectsRememberedDestinationThatOverlapsAutoDetectedSource() {
        let inspector = StubInspector(
            mounted: [
                .init(path: "/Volumes/SD_CARD", hasDCIM: true, isRemovable: true),
            ],
            likely: [
                .init(path: "/Volumes/SD_CARD", hasDCIM: true, isRemovable: true),
            ]
        )
        let resolver = VolumeResolver(
            explicitSourcePath: nil,
            explicitDestinationPath: nil,
            inspector: inspector,
            watcher: StubWatcher(result: .failure(.timedOut(seconds: 60))),
            destinationMemory: StubDestinationMemory(loadedPath: "/Volumes/SD_CARD"),
            logger: StructuredLogger(verbose: false),
            isInteractive: false
        )

        XCTAssertThrowsError(try resolver.resolve()) { error in
            guard let volumeError = error as? VolumeResolverError,
                  case let VolumeResolverError.overlappingPaths(sourcePath, destinationPath, relation) = volumeError else {
                return XCTFail("Unexpected error: \(error)")
            }

            XCTAssertEqual(sourcePath, "/Volumes/SD_CARD")
            XCTAssertEqual(destinationPath, "/Volumes/SD_CARD")
            XCTAssertEqual(relation, .same)
        }
    }

    func testResolveAllowsDisjointSameDriveSiblingDirectories() throws {
        let source = try createDirectory(named: "card")
        let destination = try createDirectory(named: "card-backup")

        let resolver = VolumeResolver(
            explicitSourcePath: source.path,
            explicitDestinationPath: destination.path,
            inspector: StubInspector(mounted: [], likely: []),
            watcher: StubWatcher(result: .failure(.timedOut(seconds: 60))),
            destinationMemory: StubDestinationMemory(loadedPath: nil),
            logger: StructuredLogger(verbose: false),
            isInteractive: false
        )

        let resolved = try resolver.resolve()

        XCTAssertEqual(resolved.sourceURL.path, source.path)
        XCTAssertEqual(resolved.destinationURL.path, destination.path)
    }

    private func createDirectory(named name: String) throws -> URL {
        let url = tempRoot.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

final class ReceiptBasedDestinationMemoryTests: XCTestCase {
    private var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("fyluro-memory-\(UUID().uuidString.lowercased())", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
    }

    func testLoadPrefersMostRecentlyModifiedReceiptsDirectory() throws {
        let volumeA = tempRoot.appendingPathComponent("A", isDirectory: true)
        let volumeB = tempRoot.appendingPathComponent("B", isDirectory: true)
        try FileManager.default.createDirectory(at: volumeA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: volumeB, withIntermediateDirectories: true)

        let receiptsA = volumeA.appendingPathComponent("_ingest_receipts", isDirectory: true)
        let receiptsB = volumeB.appendingPathComponent("_ingest_receipts", isDirectory: true)
        try FileManager.default.createDirectory(at: receiptsA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: receiptsB, withIntermediateDirectories: true)

        let earlier = Date(timeIntervalSince1970: 1_700_000_000)
        let later = Date(timeIntervalSince1970: 1_700_100_000)
        try FileManager.default.setAttributes([.modificationDate: earlier], ofItemAtPath: receiptsA.path)
        try FileManager.default.setAttributes([.modificationDate: later], ofItemAtPath: receiptsB.path)

        let memory = ReceiptBasedDestinationMemory(fileManager: .default)
        let remembered = memory.loadLastDestinationPath(from: [
            .init(path: volumeA.path, hasDCIM: false, isRemovable: false),
            .init(path: volumeB.path, hasDCIM: false, isRemovable: false),
        ])

        XCTAssertEqual(remembered, volumeB.path)
    }
}

final class VolumesWatcherTests: XCTestCase {
    func testWatcherReturnsNewLikelyCardOutsideBaseline() throws {
        let inspector = SequencedLikelyInspector(sequences: [
            [],
            [.init(path: "/Volumes/SD_NEW", hasDCIM: true, isRemovable: true)],
        ])
        var current = Date(timeIntervalSince1970: 0)
        let watcher = VolumesWatcher(
            inspector: inspector,
            pollInterval: 0,
            sleep: { _ in },
            now: {
                defer { current = current.addingTimeInterval(0.5) }
                return current
            }
        )

        let detected = try watcher.waitForNewLikelyCard(timeout: 5, baselinePaths: Set(["/Volumes/Existing"]))

        XCTAssertEqual(detected.path, "/Volumes/SD_NEW")
    }

    func testWatcherTimesOutWhenNoNewCardAppears() throws {
        let inspector = SequencedLikelyInspector(sequences: [[], [], []])
        var current = Date(timeIntervalSince1970: 0)
        let watcher = VolumesWatcher(
            inspector: inspector,
            pollInterval: 0,
            sleep: { _ in },
            now: {
                defer { current = current.addingTimeInterval(1) }
                return current
            }
        )

        XCTAssertThrowsError(
            try watcher.waitForNewLikelyCard(timeout: 2, baselinePaths: [])
        ) { error in
            XCTAssertEqual(error as? VolumesWatcherError, .timedOut(seconds: 2))
        }
    }
}

private final class StubInspector: VolumeInspecting {
    private let mounted: [MountedVolume]
    private let likely: [MountedVolume]

    init(mounted: [MountedVolume], likely: [MountedVolume]) {
        self.mounted = mounted
        self.likely = likely
    }

    func mountedVolumes() -> [MountedVolume] {
        mounted
    }

    func likelyCardVolumes() -> [MountedVolume] {
        likely
    }
}

private final class StubWatcher: VolumesWatching {
    private let result: Result<MountedVolume, VolumesWatcherError>
    private(set) var receivedBaselinePaths: Set<String> = []

    init(result: Result<MountedVolume, VolumesWatcherError>) {
        self.result = result
    }

    func waitForNewLikelyCard(timeout: TimeInterval?, baselinePaths: Set<String>) throws -> MountedVolume {
        receivedBaselinePaths = baselinePaths
        return try result.get()
    }
}

private final class StubDestinationMemory: DestinationRemembering {
    private let loadedPath: String?

    init(loadedPath: String?) {
        self.loadedPath = loadedPath
    }

    func loadLastDestinationPath(from mountedVolumes: [MountedVolume]) -> String? {
        loadedPath
    }
}

private final class SequencedLikelyInspector: VolumeInspecting {
    private let sequences: [[MountedVolume]]
    private var index = 0

    init(sequences: [[MountedVolume]]) {
        self.sequences = sequences
    }

    func mountedVolumes() -> [MountedVolume] {
        []
    }

    func likelyCardVolumes() -> [MountedVolume] {
        guard !sequences.isEmpty else {
            return []
        }
        defer {
            if index < sequences.count - 1 {
                index += 1
            }
        }
        return sequences[index]
    }
}
