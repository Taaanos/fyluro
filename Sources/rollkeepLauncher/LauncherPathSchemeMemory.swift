import Foundation
import RollKeepCore

struct LauncherPathSchemeConfiguration: Equatable, Sendable {
    var chronologicalLayout: PathChronologicalLayout
    var includeCameraFolder: Bool
    var splitPhotoCompression: Bool

    static let `default` = LauncherPathSchemeConfiguration(
        chronologicalLayout: .yearYearMonthCompact,
        includeCameraFolder: true,
        splitPhotoCompression: false
    )

    var corePathScheme: ImportPathScheme {
        ImportPathScheme(
            chronologicalLayout: chronologicalLayout,
            includeCameraFolder: includeCameraFolder,
            splitPhotoCompression: splitPhotoCompression
        )
    }
}

protocol LauncherPathSchemeRemembering {
    func loadAppliedPathScheme() -> LauncherPathSchemeConfiguration
    func saveAppliedPathScheme(_ configuration: LauncherPathSchemeConfiguration)
}

struct LauncherPathSchemeMemory: LauncherPathSchemeRemembering {
    let userDefaults: UserDefaults
    let chronologicalKey: String
    let includeCameraKey: String
    let splitPhotoCompressionKey: String

    init(
        userDefaults: UserDefaults = .standard,
        chronologicalKey: String = "rollkeep.launcher.pathScheme.chronologicalLayout",
        includeCameraKey: String = "rollkeep.launcher.pathScheme.includeCameraFolder",
        splitPhotoCompressionKey: String = "rollkeep.launcher.pathScheme.splitPhotoCompression"
    ) {
        self.userDefaults = userDefaults
        self.chronologicalKey = chronologicalKey
        self.includeCameraKey = includeCameraKey
        self.splitPhotoCompressionKey = splitPhotoCompressionKey
    }

    func loadAppliedPathScheme() -> LauncherPathSchemeConfiguration {
        let chronologicalLayout: PathChronologicalLayout
        if let rawValue = userDefaults.string(forKey: chronologicalKey),
           let parsed = PathChronologicalLayout.parseCLIValue(rawValue) {
            chronologicalLayout = parsed
        } else {
            chronologicalLayout = .yearYearMonthCompact
        }

        let includeCameraFolder = userDefaults.object(forKey: includeCameraKey) == nil
            ? true
            : userDefaults.bool(forKey: includeCameraKey)
        let splitPhotoCompression = userDefaults.object(forKey: splitPhotoCompressionKey) == nil
            ? false
            : userDefaults.bool(forKey: splitPhotoCompressionKey)

        return LauncherPathSchemeConfiguration(
            chronologicalLayout: chronologicalLayout,
            includeCameraFolder: includeCameraFolder,
            splitPhotoCompression: splitPhotoCompression
        )
    }

    func saveAppliedPathScheme(_ configuration: LauncherPathSchemeConfiguration) {
        userDefaults.set(configuration.chronologicalLayout.rawValue, forKey: chronologicalKey)
        userDefaults.set(configuration.includeCameraFolder, forKey: includeCameraKey)
        userDefaults.set(configuration.splitPhotoCompression, forKey: splitPhotoCompressionKey)
    }
}

