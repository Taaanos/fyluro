import XCTest
@testable import fyluroLauncher
@testable import FyluroCore

struct StubLauncherSourceDefaulting: LauncherSourceDefaulting {
    let path: String?

    func suggestedSourcePath() -> String? {
        path
    }
}

struct StubLauncherDestinationDefaulting: LauncherDestinationDefaulting {
    let path: String?

    func suggestedDestinationPath() -> String? {
        path
    }
}

final class StubLauncherDestinationRemembering: LauncherDestinationRemembering {
    private let initialPath: String?
    private(set) var savedPaths: [String] = []

    init(initialPath: String?) {
        self.initialPath = initialPath
    }

    func loadLastDestinationPath() -> String? {
        initialPath
    }

    func saveLastDestinationPath(_ path: String) {
        savedPaths.append(path)
    }
}

final class StubLauncherPathSchemeRemembering: LauncherPathSchemeRemembering {
    private let initialConfiguration: LauncherPathSchemeConfiguration
    private(set) var savedConfigurations: [LauncherPathSchemeConfiguration] = []

    init(initialConfiguration: LauncherPathSchemeConfiguration) {
        self.initialConfiguration = initialConfiguration
    }

    func loadAppliedPathScheme() -> LauncherPathSchemeConfiguration {
        savedConfigurations.last ?? initialConfiguration
    }

    func saveAppliedPathScheme(_ configuration: LauncherPathSchemeConfiguration) {
        savedConfigurations.append(configuration)
    }
}

final class StubLauncherFinderOpening: LauncherFinderOpening {
    private(set) var revealedURLs: [[URL]] = []
    private(set) var openedDirectories: [String] = []

    func reveal(_ urls: [URL]) {
        revealedURLs.append(urls)
    }

    @discardableResult
    func openDirectory(_ url: URL) -> Bool {
        openedDirectories.append(url.path)
        return true
    }
}
