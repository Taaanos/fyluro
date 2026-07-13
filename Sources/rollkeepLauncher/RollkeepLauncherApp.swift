import SwiftUI

@main
struct RollkeepLauncherApp: App {
    @StateObject private var pathSchemeSettingsStore = LauncherPathSchemeSettingsStore()

    var body: some Scene {
        WindowGroup {
            LauncherContentView(pathSchemeSettingsStore: pathSchemeSettingsStore)
        }
        .defaultSize(width: LauncherWindowMetrics.idealWidth, height: LauncherWindowMetrics.setupHeight)
        .windowResizability(.contentSize)

        Settings {
            LauncherSettingsView(pathSchemeSettingsStore: pathSchemeSettingsStore)
        }
        .defaultSize(width: LauncherSettingsWindowMetrics.width, height: LauncherSettingsWindowMetrics.height)
        .windowResizability(.contentSize)
    }
}

enum LauncherWindowMetrics {
    static let minWidth: CGFloat = 520
    static let idealWidth: CGFloat = 560
    static let compactHeight: CGFloat = 388
    static let setupHeight: CGFloat = 438
    static let emptyInventoryCardMinHeight: CGFloat = 132
    static let cameraInventoryMaxHeight: CGFloat = 80
    static let maxVisibleCameraRows = 3
    static let completionWarningListMaxHeight: CGFloat = 140
    static let maxVisibleCompletionWarningRows = 4

    static func preferredContentHeight(for uiState: LauncherUIState) -> CGFloat {
        preferredContentHeight(for: uiState, measuredHeight: nil)
    }

    static func preferredContentHeight(for uiState: LauncherUIState, measuredHeight: CGFloat?) -> CGFloat {
        let fallbackHeight: CGFloat
        switch uiState {
        case .idle, .ready:
            fallbackHeight = setupHeight
        case .running, .success, .failure:
            fallbackHeight = compactHeight
        }

        guard let measuredHeight else {
            return fallbackHeight
        }

        return max(fallbackHeight, measuredHeight)
    }
}

enum LauncherSettingsWindowMetrics {
    static let width: CGFloat = 560
    static let height: CGFloat = 640
}
