import Foundation
import RollKeepCore
import RollKeepEngine
import XCTest
@testable import rollkeepLauncher

private final class InMemoryParallelCopiesMemory: LauncherParallelCopiesRemembering, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Int

    init(initial: Int = 1) {
        stored = initial
    }

    func loadPreferredParallelCopies() -> Int {
        lock.lock(); defer { lock.unlock() }
        return stored
    }

    func savePreferredParallelCopies(_ count: Int) {
        lock.lock(); defer { lock.unlock() }
        stored = count
    }
}

private struct PathMappedMediumDetector: DestinationMediumDetecting {
    let mapping: [String: DestinationMediumType]

    func detectMediumType(at destinationURL: URL) -> DestinationMediumType {
        let standardized = destinationURL.standardizedFileURL.path
        return mapping[standardized] ?? .unknown
    }
}

final class LauncherTransferSettingsTests: XCTestCase {
    private var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("rollkeep-transfer-settings-\(UUID().uuidString.lowercased())", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
    }

    func testParallelCopiesMemoryDefaultsToOneAndNormalizesValues() throws {
        let suite = "rollkeep-parallel-copies-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let memory = LauncherParallelCopiesMemory(userDefaults: defaults)
        XCTAssertEqual(memory.loadPreferredParallelCopies(), 1)

        memory.savePreferredParallelCopies(2)
        XCTAssertEqual(LauncherParallelCopiesMemory(userDefaults: defaults).loadPreferredParallelCopies(), 2)

        memory.savePreferredParallelCopies(9)
        XCTAssertEqual(memory.loadPreferredParallelCopies(), 1)
    }

    @MainActor
    func testTransferSettingsStoreLocksHDDToOneWithoutErasingSavedNonHDDChoice() throws {
        let ssdDir = tempRoot.appendingPathComponent("ssd", isDirectory: true)
        let hddDir = tempRoot.appendingPathComponent("hdd", isDirectory: true)
        let unknownDir = tempRoot.appendingPathComponent("unknown", isDirectory: true)
        try FileManager.default.createDirectory(at: ssdDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: hddDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: unknownDir, withIntermediateDirectories: true)

        let memory = InMemoryParallelCopiesMemory(initial: 1)
        let detector = PathMappedMediumDetector(mapping: [
            ssdDir.standardizedFileURL.path: .solidState,
            hddDir.standardizedFileURL.path: .rotationalHDD,
            unknownDir.standardizedFileURL.path: .unknown,
        ])
        let store = LauncherTransferSettingsStore(memory: memory, mediumDetector: detector)

        XCTAssertNil(store.detectedMediumType)
        XCTAssertEqual(store.detectedMediumDisplayText, "No destination selected")
        XCTAssertEqual(store.effectiveMaxParallelCopies, 1)
        XCTAssertFalse(store.isParallelCopiesLockedToSingleStream)

        store.updateDestinationPath(ssdDir.path)
        XCTAssertEqual(store.detectedMediumType, .solidState)
        XCTAssertEqual(store.detectedMediumDisplayText, "SSD")
        XCTAssertEqual(store.effectiveMaxParallelCopies, 1)

        store.setPreferredMaxParallelCopies(2)
        XCTAssertEqual(store.effectiveMaxParallelCopies, 2)
        XCTAssertEqual(memory.loadPreferredParallelCopies(), 2)

        store.updateDestinationPath(hddDir.path)
        XCTAssertEqual(store.detectedMediumType, .rotationalHDD)
        XCTAssertEqual(store.detectedMediumDisplayText, "HDD")
        XCTAssertTrue(store.isParallelCopiesLockedToSingleStream)
        XCTAssertEqual(store.effectiveMaxParallelCopies, 1)
        XCTAssertEqual(store.explanationFootnoteText, "Locked to 1 for spinning disks to prevent slow head seeks.")
        XCTAssertEqual(store.preferredMaxParallelCopies, 2)

        store.updateDestinationPath(unknownDir.path)
        XCTAssertEqual(store.detectedMediumType, .unknown)
        XCTAssertEqual(store.detectedMediumDisplayText, "Unknown")
        XCTAssertFalse(store.isParallelCopiesLockedToSingleStream)
        XCTAssertEqual(store.effectiveMaxParallelCopies, 2)
    }

    @MainActor
    func testViewModelIngestRequestRespectsPreferenceAndLocksHDDToOne() throws {
        let ssdDir = tempRoot.appendingPathComponent("ssd", isDirectory: true)
        let hddDir = tempRoot.appendingPathComponent("hdd", isDirectory: true)
        let sourceDir = tempRoot.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: ssdDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: hddDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)

        let memory = InMemoryParallelCopiesMemory(initial: 1)
        let detector = PathMappedMediumDetector(mapping: [
            ssdDir.standardizedFileURL.path: .solidState,
            hddDir.standardizedFileURL.path: .rotationalHDD,
        ])
        let transferStore = LauncherTransferSettingsStore(memory: memory, mediumDetector: detector)

        let viewModel = LauncherViewModel(
            destinationRemembering: StubLauncherDestinationRemembering(initialPath: nil),
            destinationDefaulting: StubLauncherDestinationDefaulting(path: nil),
            transferSettingsStore: transferStore
        )

        viewModel.sourcePath = sourceDir.path
        viewModel.destinationPath = ssdDir.path
        XCTAssertEqual(viewModel.ingestRequest().maxParallelCopies, 1)

        transferStore.setPreferredMaxParallelCopies(2)
        XCTAssertEqual(viewModel.ingestRequest().maxParallelCopies, 2)

        viewModel.destinationPath = hddDir.path
        XCTAssertEqual(viewModel.ingestRequest().maxParallelCopies, 1)
    }
}
