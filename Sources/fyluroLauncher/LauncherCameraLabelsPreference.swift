import Foundation

/// The "Use camera labels (experimental)" setting (ROL-6 Section 6). It is off by default.
/// The scan preview and the ingest request both read it here. The ingest request reads it once,
/// at the start of a run (I-10).
protocol LauncherCameraLabelsPreferring: Sendable {
    var isEnabled: Bool { get nonmutating set }
}

struct LauncherCameraLabelsPreference: LauncherCameraLabelsPreferring, @unchecked Sendable {
    static let defaultsKey = "fyluro.launcher.cameraLabels.enabled"

    private let userDefaults: UserDefaults
    private let key: String

    init(userDefaults: UserDefaults = .standard, key: String = LauncherCameraLabelsPreference.defaultsKey) {
        self.userDefaults = userDefaults
        self.key = key
    }

    var isEnabled: Bool {
        get { userDefaults.bool(forKey: key) }
        nonmutating set { userDefaults.set(newValue, forKey: key) }
    }
}
