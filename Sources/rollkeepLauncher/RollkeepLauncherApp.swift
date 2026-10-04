import SwiftUI

@main
struct RollkeepLauncherApp: App {
    @StateObject private var pathSchemeSettingsStore = LauncherPathSchemeSettingsStore()
    @StateObject private var cameraCatalogStore = LauncherCameraCatalogStore()

    var body: some Scene {
        WindowGroup {
            LauncherContentView(
                pathSchemeSettingsStore: pathSchemeSettingsStore,
                cameraCatalogStore: cameraCatalogStore
            )
        }
        .windowResizability(.contentSize)

        Settings {
            LauncherSettingsRootView(
                pathSchemeSettingsStore: pathSchemeSettingsStore,
                cameraCatalogStore: cameraCatalogStore
            )
        }
        .defaultSize(width: LauncherSettingsWindowMetrics.width, height: LauncherSettingsWindowMetrics.height)
        .windowResizability(.contentSize)
    }
}

enum LauncherWindowMetrics {
    static let minWidth: CGFloat = 520
    static let idealWidth: CGFloat = 560
    static let cameraInventoryMaxHeight: CGFloat = 96
    static let maxVisibleCameraRows = 3
    static let completionWarningListMaxHeight: CGFloat = 140
    static let maxVisibleCompletionWarningRows = 4
    static let filmModeSheetMaxHeight: CGFloat = 420
}

enum LauncherSettingsWindowMetrics {
    static let width: CGFloat = 560
    static let height: CGFloat = 640
}
