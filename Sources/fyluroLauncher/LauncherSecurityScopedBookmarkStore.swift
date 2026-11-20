import Foundation

enum LauncherSecurityScopedSlot {
    case source
    case destination
}

protocol LauncherSecurityScopedBookmarking: AnyObject {
    func activateAccess(for url: URL, slot: LauncherSecurityScopedSlot)
    func stopAccess(for slot: LauncherSecurityScopedSlot)
    func stopAllAccess()
    func saveDestinationBookmark(for url: URL)
    func clearDestinationBookmark()
    func restoreDestinationBookmark() -> URL?
}

/// Manages App Sandbox security-scoped resource access for the active source
/// and destination folders and persists the destination bookmark across launches.
final class LauncherSecurityScopedBookmarkStore: LauncherSecurityScopedBookmarking {
    static let defaultDestinationBookmarkKey = "fyluro.launcher.lastDestinationBookmark"

    private let userDefaults: UserDefaults
    private let destinationBookmarkKey: String
    private let makeBookmarkData: (URL) throws -> Data
    private let resolveBookmarkData: (Data) throws -> (url: URL, isStale: Bool)
    private let startAccessing: (URL) -> Bool
    private let stopAccessing: (URL) -> Void
    private var activeResources: [LauncherSecurityScopedSlot: URL] = [:]

    init(
        userDefaults: UserDefaults = .standard,
        destinationBookmarkKey: String = LauncherSecurityScopedBookmarkStore.defaultDestinationBookmarkKey,
        makeBookmarkData: @escaping (URL) throws -> Data = { url in
            try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        },
        resolveBookmarkData: @escaping (Data) throws -> (url: URL, isStale: Bool) = { data in
            var isStale = false
            let url = try URL(
                resolvingBookmarkData: data,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            return (url, isStale)
        },
        startAccessing: @escaping (URL) -> Bool = { $0.startAccessingSecurityScopedResource() },
        stopAccessing: @escaping (URL) -> Void = { $0.stopAccessingSecurityScopedResource() }
    ) {
        self.userDefaults = userDefaults
        self.destinationBookmarkKey = destinationBookmarkKey
        self.makeBookmarkData = makeBookmarkData
        self.resolveBookmarkData = resolveBookmarkData
        self.startAccessing = startAccessing
        self.stopAccessing = stopAccessing
    }

    deinit {
        stopAllAccess()
    }

    func activateAccess(for url: URL, slot: LauncherSecurityScopedSlot) {
        if let existing = activeResources[slot],
           existing.standardizedFileURL == url.standardizedFileURL {
            return
        }

        stopAccess(for: slot)
        if startAccessing(url) {
            activeResources[slot] = url
        }
    }

    func stopAccess(for slot: LauncherSecurityScopedSlot) {
        guard let previous = activeResources.removeValue(forKey: slot) else {
            return
        }
        stopAccessing(previous)
    }

    func stopAllAccess() {
        for url in activeResources.values {
            stopAccessing(url)
        }
        activeResources.removeAll()
    }

    func saveDestinationBookmark(for url: URL) {
        do {
            let data = try makeBookmarkData(url)
            userDefaults.set(data, forKey: destinationBookmarkKey)
        } catch {
            clearDestinationBookmark()
        }
    }

    func clearDestinationBookmark() {
        userDefaults.removeObject(forKey: destinationBookmarkKey)
    }

    func restoreDestinationBookmark() -> URL? {
        guard let data = userDefaults.data(forKey: destinationBookmarkKey) else {
            return nil
        }

        do {
            let resolved = try resolveBookmarkData(data)
            activateAccess(for: resolved.url, slot: .destination)
            if resolved.isStale {
                saveDestinationBookmark(for: resolved.url)
            }
            return resolved.url
        } catch {
            clearDestinationBookmark()
            return nil
        }
    }
}
