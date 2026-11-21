import SwiftUI

@main
struct FyluroLauncherApp: App {
    @NSApplicationDelegateAdaptor(FyluroAppDelegate.self) private var appDelegate
    @StateObject private var pathSchemeSettingsStore = LauncherPathSchemeSettingsStore()
    @StateObject private var cameraCatalogStore = LauncherCameraCatalogStore()
    @StateObject private var transferSettingsStore = LauncherTransferSettingsStore()
    @StateObject private var windowCoordinator = LauncherMainWindowCoordinator()
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        let _ = configureWindowHandling()

        WindowGroup(id: LauncherSceneID.main) {
            LauncherContentView(
                pathSchemeSettingsStore: pathSchemeSettingsStore,
                cameraCatalogStore: cameraCatalogStore,
                transferSettingsStore: transferSettingsStore,
                windowCoordinator: windowCoordinator
            )
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Window") {
                    windowCoordinator.openNewWindowIfNeeded()
                }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(windowCoordinator.hasMainWindow)
            }
        }

        Settings {
            LauncherSettingsRootView(
                pathSchemeSettingsStore: pathSchemeSettingsStore,
                cameraCatalogStore: cameraCatalogStore,
                transferSettingsStore: transferSettingsStore
            )
        }
        .windowResizability(.contentSize)
    }

    private func configureWindowHandling() {
        appDelegate.windowCoordinator = windowCoordinator
        windowCoordinator.openWindowHandler = {
            openWindow(id: LauncherSceneID.main)
        }
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
    static let filmModeSheetWidth: CGFloat = 480
    static let filmModeSheetHeight: CGFloat = 640
}

enum LauncherSettingsWindowMetrics {
    static let width: CGFloat = 560
    static let maxPaneHeight: CGFloat = 720
}
