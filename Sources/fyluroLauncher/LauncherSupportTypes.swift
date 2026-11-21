import AppKit
import Foundation
import FyluroCore
import FyluroEngine

enum LauncherFilmModeState: Equatable {
    case disabled
    case enabled(FilmModeOverride)

    var isEnabled: Bool {
        if case .enabled = self {
            return true
        }
        return false
    }

    var configuration: FilmModeOverride? {
        if case let .enabled(override) = self {
            return override
        }
        return nil
    }
}

enum LauncherUIState {
    case idle
    case ready
    case running
    case success
    case failure
}

enum LauncherRunState: Equatable {
    case idle
    case ready
    case running(stopRequested: Bool)
    case succeeded(idempotentRerun: Bool)
    case failed(stoppedByUser: Bool)

    var uiState: LauncherUIState {
        switch self {
        case .idle:
            return .idle
        case .ready:
            return .ready
        case .running:
            return .running
        case .succeeded:
            return .success
        case .failed:
            return .failure
        }
    }
}

enum LauncherDestinationSpaceState: Equatable {
    case unchecked
    case sufficient(availableBytes: Int64)
    case insufficient(DestinationSpaceChecker.InsufficientSpace, overrideAccepted: Bool)
    case unableToDetermine(String)

    init(outcome: DestinationSpaceChecker.CheckOutcome) {
        switch outcome {
        case .sufficient(let availableBytes):
            self = .sufficient(availableBytes: availableBytes)
        case .insufficient(let details):
            self = .insufficient(details, overrideAccepted: false)
        case .unableToDetermine(let reason):
            self = .unableToDetermine(reason)
        }
    }

    var checkOutcome: DestinationSpaceChecker.CheckOutcome? {
        switch self {
        case .unchecked:
            return nil
        case .sufficient(let availableBytes):
            return .sufficient(availableBytes: availableBytes)
        case .insufficient(let details, _):
            return .insufficient(details)
        case .unableToDetermine(let reason):
            return .unableToDetermine(reason)
        }
    }

    var isBlocking: Bool {
        if case .insufficient(_, overrideAccepted: false) = self {
            return true
        }
        return false
    }

    var isOverrideAccepted: Bool {
        if case .insufficient(_, overrideAccepted: true) = self {
            return true
        }
        return false
    }
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
