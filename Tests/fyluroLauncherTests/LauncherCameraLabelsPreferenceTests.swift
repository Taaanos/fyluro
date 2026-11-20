import Foundation
import XCTest
@testable import FyluroCore
@testable import fyluroLauncher

final class InMemoryCameraLabelsPreference: LauncherCameraLabelsPreferring, @unchecked Sendable {
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

final class LauncherCameraLabelsPreferenceTests: XCTestCase {
    func testPreferenceIsOffByDefaultAndRemembersChanges() throws {
        let suite = "fyluro-camera-labels-pref-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let preference = LauncherCameraLabelsPreference(userDefaults: defaults)
        XCTAssertFalse(preference.isEnabled)

        preference.isEnabled = true
        XCTAssertTrue(LauncherCameraLabelsPreference(userDefaults: defaults).isEnabled)
    }

    @MainActor
    func testIngestRequestReadsThePreferenceAtRequestTime() {
        let preference = InMemoryCameraLabelsPreference(isEnabled: false)
        let viewModel = LauncherViewModel(
            destinationRemembering: StubLauncherDestinationRemembering(initialPath: nil),
            destinationDefaulting: StubLauncherDestinationDefaulting(path: nil),
            cameraLabelsPreference: preference
        )

        XCTAssertFalse(viewModel.ingestRequest().useCameraCatalog)

        preference.isEnabled = true
        XCTAssertTrue(viewModel.ingestRequest().useCameraCatalog)
    }
}
