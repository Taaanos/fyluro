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
        .windowResizability(.contentSize)
    }
}

enum LauncherWindowMetrics {
    static let minWidth: CGFloat = 520
    static let idealWidth: CGFloat = 560
    /// The height of the setup screen with a scanned card. Every state uses at least this height,
    /// so the window keeps its size when the state changes.
    static let minContentHeight: CGFloat = 612
    static let cameraInventoryMaxHeight: CGFloat = 96
    static let maxVisibleCameraRows = 3
    static let completionWarningListMaxHeight: CGFloat = 140
    static let maxVisibleCompletionWarningRows = 4
    /// The Film Mode sheet has a fixed size. Its Form scrolls inside, and Cancel and Apply stay visible.
    static let filmModeSheetWidth: CGFloat = 480
    static let filmModeSheetHeight: CGFloat = 640
}

enum LauncherSettingsWindowMetrics {
    /// Each pane sizes its own height to its content. Only the width is fixed.
    static let width: CGFloat = 560
}
