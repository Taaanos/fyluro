import Foundation
import XCTest
@testable import RollKeepCore
@testable import rollkeepLauncher

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
    func testStartsEmptyWhenFileIsMissing() {
        let store = LauncherCameraCatalogStore(remembering: InMemoryCatalogRemembering(.missing))

        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertNil(store.loadWarning)
    }

    func testSaveNormalizesCodePersistsAndBumpsRevision() {
        let memory = InMemoryCatalogRemembering()
        let store = LauncherCameraCatalogStore(remembering: memory)

        XCTAssertTrue(store.save(code: " sm-a546b ", name: "  Galaxy A54 5G "))

        XCTAssertEqual(store.entries, ["SM-A546B": "Galaxy A54 5G"])
        XCTAssertEqual(memory.saved, [["SM-A546B": "Galaxy A54 5G"]])
        XCTAssertEqual(store.revision, 1)
        XCTAssertEqual(store.name(forCode: "sm-a546b"), "Galaxy A54 5G")
    }

    func testSavingUnchangedLabelDoesNotWriteOrBumpRevision() {
        let memory = InMemoryCatalogRemembering(.loaded(["AC003": "OsmoAction4"]))
        let store = LauncherCameraCatalogStore(remembering: memory)

        XCTAssertTrue(store.save(code: "ac003", name: "OsmoAction4"))

        XCTAssertTrue(memory.saved.isEmpty)
        XCTAssertEqual(store.revision, 0)
    }

    func testValidationRejectsBlankCodeBlankNameAndNamesWithNoUsableCharacters() {
        let store = LauncherCameraCatalogStore(remembering: InMemoryCatalogRemembering())

        XCTAssertNotNil(store.validationMessage(code: "  ", name: "Galaxy"))
        XCTAssertNotNil(store.validationMessage(code: "AC003", name: "   "))
        XCTAssertNotNil(store.validationMessage(code: "AC003", name: "日本カメラ"))
        XCTAssertNil(store.validationMessage(code: "AC003", name: "Sony α7 IV"))

        XCTAssertFalse(store.save(code: "AC003", name: "日本カメラ"))
        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertEqual(store.revision, 0)
    }

    func testDeleteRemovesEntryAndBumpsRevision() {
        let memory = InMemoryCatalogRemembering(.loaded(["AC003": "OsmoAction4", "FC8482": "Mini4 Pro"]))
        let store = LauncherCameraCatalogStore(remembering: memory)

        XCTAssertTrue(store.delete(code: "ac003"))

        XCTAssertEqual(store.entries, ["FC8482": "Mini4 Pro"])
        XCTAssertEqual(store.revision, 1)
    }

    func testCodesSharingFolderReportsOtherCodesResolvingToTheSameFolder() {
        let store = LauncherCameraCatalogStore(
            remembering: InMemoryCatalogRemembering(.loaded(["AC003": "Osmo Action 4"]))
        )

        XCTAssertEqual(store.codesSharingFolder(code: "PP-101", name: "osmo action 4"), ["AC003"])
        XCTAssertEqual(store.codesSharingFolder(code: "AC003", name: "Osmo Action 4"), [])
    }

    func testSaveRejectsANameThatAnotherCodeAlreadyUses() {
        let memory = InMemoryCatalogRemembering(.loaded(["AC003": "Osmo Action 4"]))
        let store = LauncherCameraCatalogStore(remembering: memory)

        XCTAssertNotNil(store.validationMessage(code: "PP-101", name: "osmo action 4"))
        XCTAssertFalse(store.save(code: "PP-101", name: "osmo action 4"))
        XCTAssertEqual(store.entries, ["AC003": "Osmo Action 4"])
        XCTAssertEqual(store.revision, 0)
    }

    func testSaveAllowsRenamingACodeToItsOwnFolder() {
        let store = LauncherCameraCatalogStore(
            remembering: InMemoryCatalogRemembering(.loaded(["AC003": "Osmo Action 4"]))
        )

        XCTAssertNil(store.validationMessage(code: "ac003", name: "osmo action 4"))
    }

    func testDetectedCamerasKeepOnlyModelsAndHideOnesAlreadyLabeled() {
        let store = LauncherCameraCatalogStore(
            remembering: InMemoryCatalogRemembering(.loaded(["SM-A546B": "Galaxy A54 5G"]))
        )

        store.updateDetectedCameras(from: [
            LauncherSourceCameraSummary(label: "sm-a546b", fileCount: 3, rawModelCode: "SM-A546B"),
            LauncherSourceCameraSummary(label: "ilce-7m4", fileCount: 2, rawModelCode: "ILCE-7M4"),
            LauncherSourceCameraSummary(label: "unknown-camera", fileCount: 1, rawModelCode: "Whatever"),
            LauncherSourceCameraSummary(label: "audio", fileCount: 1),
        ])

        XCTAssertEqual(store.detectedCameras.map(\.rawModelCode), ["SM-A546B", "ILCE-7M4"])
        XCTAssertEqual(store.unmappedDetectedCameras.map(\.rawModelCode), ["ILCE-7M4"])
    }

    func testSavingDetectedCameraMovesItOutOfTheUnmappedList() {
        let store = LauncherCameraCatalogStore(remembering: InMemoryCatalogRemembering())
        store.updateDetectedCameras(from: [
            LauncherSourceCameraSummary(label: "ilce-7m4", fileCount: 2, rawModelCode: "ILCE-7M4"),
        ])
        XCTAssertEqual(store.unmappedDetectedCameras.count, 1)

        store.save(code: "ILCE-7M4", name: "Sony A7 IV")

        XCTAssertTrue(store.unmappedDetectedCameras.isEmpty)
        XCTAssertEqual(store.savedLabels, [LauncherSavedCameraLabel(code: "ILCE-7M4", name: "Sony A7 IV")])
    }

    func testMalformedFileWarnsStartsEmptyAndClearsWarningAfterSaveWithRecoveryNotice() {
        let memory = InMemoryCatalogRemembering(.malformed("bad json"))
        memory.movedAside = URL(fileURLWithPath: "/tmp/CameraCatalog.corrupt-20260929-101500.json")
        let store = LauncherCameraCatalogStore(remembering: memory)

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
        let store = LauncherCameraCatalogStore(remembering: memory)

        XCTAssertFalse(store.save(code: "AC003", name: "OsmoAction4"))

        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertEqual(store.revision, 0)
        XCTAssertTrue(store.saveError?.contains("disk full") == true)
    }

    func testReloadPicksUpExternalEditsAndBumpsRevisionOnlyWhenChanged() {
        let memory = InMemoryCatalogRemembering(.loaded(["AC003": "OsmoAction4"]))
        let store = LauncherCameraCatalogStore(remembering: memory)

        store.reload()
        XCTAssertEqual(store.revision, 0)

        memory.result = .loaded(["AC003": "OsmoAction4", "FC8482": "Mini4 Pro"])
        store.reload()
        XCTAssertEqual(store.entries.count, 2)
        XCTAssertEqual(store.revision, 1)
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
        let fileURL = tempRoot.appendingPathComponent("RollKeep/CameraCatalog.json")
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
