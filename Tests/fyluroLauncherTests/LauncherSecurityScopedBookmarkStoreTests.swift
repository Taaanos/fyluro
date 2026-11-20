import Foundation
import XCTest
@testable import fyluroLauncher

final class LauncherSecurityScopedBookmarkStoreTests: XCTestCase {
    private var suiteName: String!
    private var userDefaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "LauncherSecurityScopedBookmarkStoreTests-\(UUID().uuidString)"
        userDefaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        if let suiteName {
            userDefaults?.removePersistentDomain(forName: suiteName)
        }
        userDefaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testSaveAndRestoreDestinationBookmarkActivatesAccess() {
        let destURL = URL(fileURLWithPath: "/tmp/fyluro-dest", isDirectory: true)
        var startedURLs: [URL] = []
        var stoppedURLs: [URL] = []

        let store = LauncherSecurityScopedBookmarkStore(
            userDefaults: userDefaults,
            makeBookmarkData: { url in Data(url.path.utf8) },
            resolveBookmarkData: { data in
                let path = String(decoding: data, as: UTF8.self)
                return (URL(fileURLWithPath: path, isDirectory: true), false)
            },
            startAccessing: { url in
                startedURLs.append(url)
                return true
            },
            stopAccessing: { url in
                stoppedURLs.append(url)
            }
        )

        store.saveDestinationBookmark(for: destURL)
        let restored = store.restoreDestinationBookmark()

        XCTAssertEqual(restored, destURL)
        XCTAssertEqual(startedURLs, [destURL])
        XCTAssertTrue(stoppedURLs.isEmpty)

        store.stopAllAccess()
        XCTAssertEqual(stoppedURLs, [destURL])
    }

    func testRestoreDestinationBookmarkClearsUnresolvableBookmark() {
        userDefaults.set(Data("corrupt-or-old-cdhash".utf8), forKey: LauncherSecurityScopedBookmarkStore.defaultDestinationBookmarkKey)

        let store = LauncherSecurityScopedBookmarkStore(
            userDefaults: userDefaults,
            resolveBookmarkData: { _ in
                throw NSError(domain: NSCocoaErrorDomain, code: 257)
            }
        )

        let restored = store.restoreDestinationBookmark()

        XCTAssertNil(restored)
        XCTAssertNil(userDefaults.data(forKey: LauncherSecurityScopedBookmarkStore.defaultDestinationBookmarkKey))
    }

    func testRestoreDestinationBookmarkRefreshesStaleBookmark() {
        let destURL = URL(fileURLWithPath: "/tmp/fyluro-stale-dest", isDirectory: true)
        var makeCount = 0

        userDefaults.set(Data("stale-data".utf8), forKey: LauncherSecurityScopedBookmarkStore.defaultDestinationBookmarkKey)

        let store = LauncherSecurityScopedBookmarkStore(
            userDefaults: userDefaults,
            makeBookmarkData: { _ in
                makeCount += 1
                return Data("refreshed-data".utf8)
            },
            resolveBookmarkData: { _ in
                (destURL, true)
            },
            startAccessing: { _ in true },
            stopAccessing: { _ in }
        )

        let restored = store.restoreDestinationBookmark()

        XCTAssertEqual(restored, destURL)
        XCTAssertEqual(makeCount, 1)
        XCTAssertEqual(
            userDefaults.data(forKey: LauncherSecurityScopedBookmarkStore.defaultDestinationBookmarkKey),
            Data("refreshed-data".utf8)
        )
    }

    func testActivateAccessStopsPreviousSlotBeforeStartingReplacement() {
        let first = URL(fileURLWithPath: "/tmp/first", isDirectory: true)
        let second = URL(fileURLWithPath: "/tmp/second", isDirectory: true)
        var events: [String] = []

        let store = LauncherSecurityScopedBookmarkStore(
            userDefaults: userDefaults,
            startAccessing: { url in
                events.append("start:\(url.path)")
                return true
            },
            stopAccessing: { url in
                events.append("stop:\(url.path)")
            }
        )

        store.activateAccess(for: first, slot: .source)
        store.activateAccess(for: second, slot: .source)

        XCTAssertEqual(events, [
            "start:/tmp/first",
            "stop:/tmp/first",
            "start:/tmp/second",
        ])
    }

    func testSandboxedAutoPickersStayIdleWithoutScanningVolumes() {
        let sourcePicker = LauncherSourceAutoPicker(
            inspector: StubVolumeInspector(),
            isSandboxed: true
        )
        let destPicker = LauncherReceiptBasedDestinationDefault(
            inspector: StubVolumeInspector(),
            isSandboxed: true
        )

        XCTAssertNil(sourcePicker.suggestedSourcePath())
        XCTAssertNil(destPicker.suggestedDestinationPath())
    }
}

private struct StubVolumeInspector: LauncherVolumeInspecting {
    func mountedVolumes() -> [LauncherMountedVolume] {
        XCTFail("mountedVolumes should not be called when sandboxed")
        return []
    }

    func likelyCardVolumes() -> [LauncherMountedVolume] {
        XCTFail("likelyCardVolumes should not be called when sandboxed")
        return []
    }
}
