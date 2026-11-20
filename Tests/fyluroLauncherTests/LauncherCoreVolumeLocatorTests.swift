import XCTest
@testable import fyluroLauncher
@testable import FyluroCore

extension LauncherCoreTests {
    func testVolumeInspectorRanksLikelyCardsByDCIMThenRemovableHint() throws {
        let fileManager = FileManager.default
        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("fyluro-launcher-volumes-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempRoot) }

        let archive = tempRoot.appendingPathComponent("ARCHIVE", isDirectory: true)
        let camera = tempRoot.appendingPathComponent("CAMERA_CARD", isDirectory: true)
        let removable = tempRoot.appendingPathComponent("USB_MEDIA", isDirectory: true)

        try fileManager.createDirectory(at: archive, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: camera.appendingPathComponent("DCIM", isDirectory: true), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: removable, withIntermediateDirectories: true)

        let removablePaths = Set([removable.path])
        let inspector = LauncherVolumeInspector(
            volumesRoot: tempRoot,
            fileManager: fileManager,
            removableHintProvider: { removablePaths.contains($0.standardizedFileURL.path) }
        )

        XCTAssertEqual(inspector.likelyCardVolumes().map(\.path), [
            camera.path,
            removable.path,
        ])
    }

    func testSourceAutoPickerUsesHighestRankedLikelyCard() throws {
        let fileManager = FileManager.default
        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("fyluro-launcher-autopick-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempRoot) }

        let preferred = tempRoot.appendingPathComponent("CARD_A", isDirectory: true)
        let fallback = tempRoot.appendingPathComponent("CARD_B", isDirectory: true)

        try fileManager.createDirectory(at: preferred.appendingPathComponent("DCIM", isDirectory: true), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: fallback, withIntermediateDirectories: true)

        let removablePaths = Set([fallback.path])
        let picker = LauncherSourceAutoPicker(
            inspector: LauncherVolumeInspector(
                volumesRoot: tempRoot,
                fileManager: fileManager,
                removableHintProvider: { removablePaths.contains($0.standardizedFileURL.path) }
            )
        )

        XCTAssertEqual(picker.suggestedSourcePath(), preferred.path)
    }

    func testDestinationAutoPickerUsesMostRecentReceiptsDirectory() throws {
        let fileManager = FileManager.default
        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("fyluro-launcher-destination-autopick-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempRoot) }

        let older = tempRoot.appendingPathComponent("ARCHIVE_A", isDirectory: true)
        let newer = tempRoot.appendingPathComponent("ARCHIVE_B", isDirectory: true)
        try fileManager.createDirectory(at: older.appendingPathComponent("_ingest_receipts", isDirectory: true), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: newer.appendingPathComponent("_ingest_receipts", isDirectory: true), withIntermediateDirectories: true)

        let olderDate = Date(timeIntervalSince1970: 1_700_000_000)
        let newerDate = Date(timeIntervalSince1970: 1_700_100_000)
        try fileManager.setAttributes(
            [.modificationDate: olderDate],
            ofItemAtPath: older.appendingPathComponent("_ingest_receipts", isDirectory: true).path
        )
        try fileManager.setAttributes(
            [.modificationDate: newerDate],
            ofItemAtPath: newer.appendingPathComponent("_ingest_receipts", isDirectory: true).path
        )

        let picker = LauncherReceiptBasedDestinationDefault(
            inspector: LauncherVolumeInspector(
                volumesRoot: tempRoot,
                fileManager: fileManager,
                removableHintProvider: { _ in false }
            ),
            fileManager: fileManager
        )

        XCTAssertEqual(picker.suggestedDestinationPath(), newer.path)
    }

    func testDestinationMemoryRoundTripsPath() {
        let suiteName = "fyluro-launcher-memory-\(UUID().uuidString)"
        guard let userDefaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Expected dedicated UserDefaults suite")
            return
        }
        defer {
            userDefaults.removePersistentDomain(forName: suiteName)
        }

        let memory = LauncherDestinationMemory(userDefaults: userDefaults, key: "lastDestination")
        XCTAssertNil(memory.loadLastDestinationPath())

        memory.saveLastDestinationPath("  /Volumes/Archive  ")
        XCTAssertEqual(memory.loadLastDestinationPath(), "/Volumes/Archive")
    }

    func testDestinationAutoPickerPrefersRememberedDestinationFromMemory() {
        let picker = LauncherDestinationAutoPicker(
            memory: StubLauncherDestinationRemembering(initialPath: "/Volumes/Remembered"),
            fallback: StubLauncherDestinationDefaulting(path: "/Volumes/Fallback")
        )

        XCTAssertEqual(picker.suggestedDestinationPath(), "/Volumes/Remembered")
    }

    func testVolumeInspectorExcludesDiskImageVolumes() throws {
        let fileManager = FileManager.default
        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("fyluro-launcher-dmg-filter-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempRoot) }

        let dmgInstaller = tempRoot.appendingPathComponent("APP_INSTALLER", isDirectory: true)
        let realCard = tempRoot.appendingPathComponent("CAMERA_CARD", isDirectory: true)

        try fileManager.createDirectory(at: dmgInstaller.appendingPathComponent("DCIM", isDirectory: true), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: realCard.appendingPathComponent("DCIM", isDirectory: true), withIntermediateDirectories: true)

        let dmgPaths = Set([dmgInstaller.path])
        let inspector = LauncherVolumeInspector(
            volumesRoot: tempRoot,
            fileManager: fileManager,
            removableHintProvider: { _ in true },
            diskImageHintProvider: { dmgPaths.contains($0.standardizedFileURL.path) }
        )

        XCTAssertEqual(inspector.mountedVolumes().map(\.path), [realCard.path])
        XCTAssertEqual(inspector.likelyCardVolumes().map(\.path), [realCard.path])
    }
}
