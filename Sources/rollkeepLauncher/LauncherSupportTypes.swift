import AppKit
import Foundation

enum LauncherUIState {
    case idle
    case ready
    case running
    case success
    case failure
}

enum OutputStreamKind: String {
    case stdout = "stdout"
    case stderr = "stderr"
}

enum LauncherSourceScanState: Equatable {
    case idle
    case scanning(LauncherSourceScopeSummary?)
    case ready(LauncherSourceScopeSummary)
    case failed(String)
}

protocol LauncherFinderOpening {
    func reveal(_ urls: [URL])
    @discardableResult
    func openDirectory(_ url: URL) -> Bool
}

struct LauncherFinderWorkspace: LauncherFinderOpening {
    func reveal(_ urls: [URL]) {
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    @discardableResult
    func openDirectory(_ url: URL) -> Bool {
        NSWorkspace.shared.open(url)
    }
}
