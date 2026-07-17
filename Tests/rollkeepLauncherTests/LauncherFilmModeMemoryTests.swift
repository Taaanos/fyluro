import Foundation
import XCTest
@testable import rollkeepLauncher

final class LauncherFilmModeMemoryTests: XCTestCase {
    func testRecordAppliedRoundTripsAllFieldsExceptDate() {
        let suiteName = "rollkeep-launcher-filmmode-\(UUID().uuidString)"
        guard let userDefaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Expected dedicated UserDefaults suite")
            return
        }
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let memory = LauncherFilmModeMemory(userDefaults: userDefaults, key: "history")
        XCTAssertTrue(memory.loadHistory().isEmpty)

        memory.recordApplied(camera: "Leica M6", filmStock: "Portra 400", iso: 400, creator: "Jane Doe", copyright: "© 2026 Jane Doe")

        let entry = memory.loadHistory().first
        XCTAssertEqual(entry?.camera, "Leica M6")
        XCTAssertEqual(entry?.filmStock, "Portra 400")
        XCTAssertEqual(entry?.iso, 400)
        XCTAssertEqual(entry?.creator, "Jane Doe")
        XCTAssertEqual(entry?.copyright, "© 2026 Jane Doe")
        // LauncherFilmModeHistoryEntry has no year/month fields at all — the date is never remembered.
    }
}
