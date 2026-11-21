import Foundation
import XCTest
@testable import FyluroCore
@testable import fyluroLauncher

private final class InMemoryCameraLabelsPreference: LauncherCameraLabelsPreferring, @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool

    init(isEnabled: Bool = false) {
        value = isEnabled
    }

    var isEnabled: Bool {
        get { lock.lock(); defer { lock.unlock() }; return value }
        set { lock.lock(); defer { lock.unlock() }; value = newValue }
    }
}

private final class InMemoryCatalogRemembering: LauncherCameraCatalogRemembering {
    var result: CameraUserCatalogLoadResult
    var saved: [[String: String]] = []
    var movedAside: URL?
    var saveError: Error?

    init(_ result: CameraUserCatalogLoadResult = .missing) {
        self.result = result
    }

    func load() -> CameraUserCatalogLoadResult { result }

    func save(_ entries: [String: String]) throws -> URL? {
        if let saveError { throw saveError }
        saved.append(entries)
        result = .loaded(entries)
        return movedAside
    }
}

@MainActor
final class LauncherCameraCatalogStoreTests: XCTestCase {
    func testMalformedFileWarnsStartsEmptyAndClearsWarningAfterSaveWithRecoveryNotice() {
        let memory = InMemoryCatalogRemembering(.malformed("bad json"))
        memory.movedAside = URL(fileURLWithPath: "/tmp/CameraCatalog.corrupt-20260929-101500.json")
        let store = LauncherCameraCatalogStore(remembering: memory, preference: InMemoryCameraLabelsPreference(isEnabled: true))

        XCTAssertNotNil(store.loadWarning)
        XCTAssertTrue(store.entries.isEmpty)

        store.save(code: "AC003", name: "OsmoAction4")

        XCTAssertNil(store.loadWarning)
        XCTAssertEqual(
            store.recoveryNotice,
            "The unreadable catalog file was kept as CameraCatalog.corrupt-20260929-101500.json."
        )
    }

    func testSaveFailureSurfacesErrorAndKeepsEntriesUnchanged() {
        struct Boom: LocalizedError { var errorDescription: String? { "disk full" } }
        let memory = InMemoryCatalogRemembering()
        memory.saveError = Boom()
        let store = LauncherCameraCatalogStore(remembering: memory, preference: InMemoryCameraLabelsPreference(isEnabled: true))

        XCTAssertFalse(store.save(code: "AC003", name: "OsmoAction4"))

        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertEqual(store.revision, 0)
        XCTAssertTrue(store.saveError?.contains("disk full") == true)
    }
}

final class LauncherCameraCatalogFileStoreTests: XCTestCase {
    private var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = try FileManager.default.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: FileManager.default.temporaryDirectory,
            create: true
        )
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    func testSaveCreatesDirectoryAndRoundTripsThroughReader() throws {
        let fileURL = tempRoot.appendingPathComponent("Fyluro/CameraCatalog.json")
        let store = LauncherCameraCatalogFileStore(fileURL: fileURL)

        XCTAssertEqual(store.load(), .missing)
        XCTAssertNil(try store.save(["SM-A546B": "Galaxy A54 5G"]))

        XCTAssertEqual(store.load(), .loaded(["SM-A546B": "Galaxy A54 5G"]))
        XCTAssertEqual(CameraUserCatalogReader(fileURL: fileURL).loadEntries(), ["SM-A546B": "Galaxy A54 5G"])
    }

    func testSaveMovesUnreadableFileAsideInsteadOfOverwritingIt() throws {
        let fileURL = tempRoot.appendingPathComponent("CameraCatalog.json")
        try "{ hand edited, broken".write(to: fileURL, atomically: true, encoding: .utf8)
        let fixedNow = Date(timeIntervalSince1970: 1_790_000_000)
        let store = LauncherCameraCatalogFileStore(fileURL: fileURL, now: { fixedNow })

        let movedAside = try XCTUnwrap(try store.save(["AC003": "OsmoAction4"]))

        XCTAssertTrue(movedAside.lastPathComponent.hasPrefix("CameraCatalog.corrupt-"))
        XCTAssertTrue(movedAside.lastPathComponent.hasSuffix(".json"))
        XCTAssertEqual(try String(contentsOf: movedAside, encoding: .utf8), "{ hand edited, broken")
        XCTAssertEqual(store.load(), .loaded(["AC003": "OsmoAction4"]))
    }

    func testSaveDoesNotMoveAValidFileAside() throws {
        let fileURL = tempRoot.appendingPathComponent("CameraCatalog.json")
        let store = LauncherCameraCatalogFileStore(fileURL: fileURL)
        _ = try store.save(["AC003": "OsmoAction4"])

        XCTAssertNil(try store.save(["AC003": "OsmoAction4", "FC8482": "Mini4 Pro"]))

        let siblings = try FileManager.default.contentsOfDirectory(atPath: tempRoot.path)
        XCTAssertEqual(siblings, ["CameraCatalog.json"])
    }
}
