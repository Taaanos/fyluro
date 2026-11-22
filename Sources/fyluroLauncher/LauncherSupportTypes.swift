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

enum LauncherFinderRevealAction: Equatable {
    case openDirectory(URL)
    case revealInParent([URL])
}

enum LauncherFinderDirectoryResolver {
    static let defaultMaxWindows = 3

    static func resolveActions(
        for directories: [String],
        destinationPath: String,
        maxWindows: Int = defaultMaxWindows
    ) -> [LauncherFinderRevealAction] {
        let trimmedDestination = destinationPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !directories.isEmpty, !trimmedDestination.isEmpty else {
            return []
        }

        let limit = max(1, maxWindows)
        let normalizedDestination = URL(fileURLWithPath: trimmedDestination, isDirectory: true).standardizedFileURL.path
        let normalizedDirectories = Array(Set(directories.map {
            URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL.path
        })).sorted()

        if normalizedDirectories.count <= limit {
            return normalizedDirectories.map { .openDirectory(URL(fileURLWithPath: $0, isDirectory: true)) }
        }

        var currentNodes = normalizedDirectories
        var parentToChildren: [String: Set<String>] = [:]

        while currentNodes.count > limit {
            var nextMap: [String: Set<String>] = [:]
            for node in currentNodes {
                let parent = steppedParent(of: node, clampedAt: normalizedDestination)
                if node != parent {
                    nextMap[parent, default: []].insert(node)
                } else {
                    nextMap[parent, default: []] = nextMap[parent, default: []]
                }
            }

            pruneDescendants(in: &nextMap)
            let nextNodes = nextMap.keys.sorted()
            parentToChildren = nextMap

            if nextNodes == currentNodes {
                break
            }
            currentNodes = nextNodes
        }

        return currentNodes.sorted().map { parent in
            let children = (parentToChildren[parent] ?? []).sorted()
            if !children.isEmpty {
                return .revealInParent(children.map { URL(fileURLWithPath: $0, isDirectory: true) })
            }
            return .openDirectory(URL(fileURLWithPath: parent, isDirectory: true))
        }
    }

    private static func steppedParent(of path: String, clampedAt destination: String) -> String {
        if path == destination {
            return destination
        }
        let parent = URL(fileURLWithPath: path, isDirectory: true)
            .deletingLastPathComponent()
            .standardizedFileURL
            .path
        if isSameOrDescendant(parent, of: destination) {
            return parent
        }
        return destination
    }

    private static func pruneDescendants(in parentToChildren: inout [String: Set<String>]) {
        let sortedKeys = parentToChildren.keys.sorted { $0.count < $1.count }
        var kept: [String] = []

        for candidate in sortedKeys {
            if let ancestor = kept.first(where: { isStrictDescendant(candidate, of: $0) }) {
                if let directChild = directChild(of: ancestor, toward: candidate) {
                    parentToChildren[ancestor, default: []].insert(directChild)
                }
                parentToChildren.removeValue(forKey: candidate)
            } else {
                kept.append(candidate)
            }
        }
    }

    private static func isSameOrDescendant(_ path: String, of ancestor: String) -> Bool {
        path == ancestor || isStrictDescendant(path, of: ancestor)
    }

    private static func isStrictDescendant(_ path: String, of ancestor: String) -> Bool {
        let prefix = ancestor.hasSuffix("/") ? ancestor : ancestor + "/"
        return path.hasPrefix(prefix)
    }

    private static func directChild(of ancestor: String, toward descendant: String) -> String? {
        let prefix = ancestor.hasSuffix("/") ? ancestor : ancestor + "/"
        guard descendant.hasPrefix(prefix) else {
            return nil
        }
        let remainder = descendant.dropFirst(prefix.count)
        guard let firstComponent = remainder.split(separator: "/").first, !firstComponent.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: ancestor, isDirectory: true)
            .appendingPathComponent(String(firstComponent), isDirectory: true)
            .standardizedFileURL
            .path
    }
}
