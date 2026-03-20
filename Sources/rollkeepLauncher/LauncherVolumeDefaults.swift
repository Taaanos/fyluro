import Foundation

struct LauncherMountedVolume: Equatable {
    let path: String
    let hasDCIM: Bool
    let isRemovable: Bool?

    var heuristicScore: Int {
        var score = 0
        if hasDCIM {
            score += 3
        }
        if isRemovable == true {
            score += 1
        }
        return score
    }
}

protocol LauncherVolumeInspecting {
    func mountedVolumes() -> [LauncherMountedVolume]
    func likelyCardVolumes() -> [LauncherMountedVolume]
}

struct LauncherVolumeInspector: LauncherVolumeInspecting {
    let volumesRoot: URL
    let fileManager: FileManager
    private let removableHintProvider: (URL) -> Bool?

    init(
        volumesRoot: URL = URL(fileURLWithPath: "/Volumes", isDirectory: true),
        fileManager: FileManager = .default,
        removableHintProvider: @escaping (URL) -> Bool? = LauncherVolumeInspector.defaultRemovableHint(for:)
    ) {
        self.volumesRoot = volumesRoot
        self.fileManager = fileManager
        self.removableHintProvider = removableHintProvider
    }

    func mountedVolumes() -> [LauncherMountedVolume] {
        let resourceKeys: Set<URLResourceKey> = [.isDirectoryKey, .isHiddenKey]
        let volumeURLs: [URL]
        do {
            volumeURLs = try fileManager.contentsOfDirectory(
                at: volumesRoot,
                includingPropertiesForKeys: Array(resourceKeys),
                options: [.skipsHiddenFiles]
            )
        } catch {
            return []
        }

        var volumes: [LauncherMountedVolume] = []
        volumes.reserveCapacity(volumeURLs.count)

        for volumeURL in volumeURLs {
            guard let values = try? volumeURL.resourceValues(forKeys: resourceKeys),
                  values.isDirectory == true,
                  values.isHidden != true else {
                continue
            }

            let standardizedPath = volumeURL.standardizedFileURL.path
            var dcimIsDirectory: ObjCBool = false
            let hasDCIM = fileManager.fileExists(
                atPath: volumeURL.appendingPathComponent("DCIM", isDirectory: true).path,
                isDirectory: &dcimIsDirectory
            ) && dcimIsDirectory.boolValue

            volumes.append(LauncherMountedVolume(
                path: standardizedPath,
                hasDCIM: hasDCIM,
                isRemovable: removableHintProvider(volumeURL)
            ))
        }

        return volumes.sorted(by: LauncherVolumeInspector.sortVolumes(_:_:))
    }

    func likelyCardVolumes() -> [LauncherMountedVolume] {
        mountedVolumes()
            .filter { $0.hasDCIM || $0.isRemovable == true }
            .sorted(by: LauncherVolumeInspector.sortLikelyVolumes(_:_:))
    }

    private static func sortVolumes(_ lhs: LauncherMountedVolume, _ rhs: LauncherMountedVolume) -> Bool {
        lhs.path < rhs.path
    }

    private static func sortLikelyVolumes(_ lhs: LauncherMountedVolume, _ rhs: LauncherMountedVolume) -> Bool {
        if lhs.heuristicScore != rhs.heuristicScore {
            return lhs.heuristicScore > rhs.heuristicScore
        }
        return lhs.path < rhs.path
    }

    private static func defaultRemovableHint(for volumeURL: URL) -> Bool? {
        let keys: Set<URLResourceKey> = [.volumeIsRemovableKey]
        guard let values = try? volumeURL.resourceValues(forKeys: keys) else {
            return nil
        }
        return values.volumeIsRemovable
    }
}

protocol LauncherSourceDefaulting {
    func suggestedSourcePath() -> String?
}

struct LauncherSourceAutoPicker: LauncherSourceDefaulting {
    let inspector: LauncherVolumeInspecting

    init(inspector: LauncherVolumeInspecting = LauncherVolumeInspector()) {
        self.inspector = inspector
    }

    func suggestedSourcePath() -> String? {
        inspector.likelyCardVolumes().first?.path
    }
}

protocol LauncherDestinationDefaulting {
    func suggestedDestinationPath() -> String?
}

protocol LauncherDestinationRemembering {
    func loadLastDestinationPath() -> String?
    func saveLastDestinationPath(_ path: String)
}

struct LauncherDestinationMemory: LauncherDestinationRemembering {
    let userDefaults: UserDefaults
    let key: String

    init(
        userDefaults: UserDefaults = .standard,
        key: String = "rollkeep.launcher.lastDestinationPath"
    ) {
        self.userDefaults = userDefaults
        self.key = key
    }

    func loadLastDestinationPath() -> String? {
        guard let path = userDefaults.string(forKey: key)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty else {
            return nil
        }

        return path
    }

    func saveLastDestinationPath(_ path: String) {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            userDefaults.removeObject(forKey: key)
            return
        }

        userDefaults.set(trimmed, forKey: key)
    }
}


struct LauncherDestinationAutoPicker: LauncherDestinationDefaulting {
    let memory: LauncherDestinationRemembering
    let fallback: LauncherDestinationDefaulting?

    init(
        memory: LauncherDestinationRemembering = LauncherDestinationMemory(),
        fallback: LauncherDestinationDefaulting? = LauncherReceiptBasedDestinationDefault()
    ) {
        self.memory = memory
        self.fallback = fallback
    }

    func suggestedDestinationPath() -> String? {
        if let remembered = memory.loadLastDestinationPath() {
            return remembered
        }

        return fallback?.suggestedDestinationPath()
    }
}

struct LauncherReceiptBasedDestinationDefault: LauncherDestinationDefaulting {
    let inspector: LauncherVolumeInspecting
    let fileManager: FileManager

    init(
        inspector: LauncherVolumeInspecting = LauncherVolumeInspector(),
        fileManager: FileManager = .default
    ) {
        self.inspector = inspector
        self.fileManager = fileManager
    }

    func suggestedDestinationPath() -> String? {
        var bestMatch: (path: String, modifiedAt: Date)?
        let keys: Set<URLResourceKey> = [.contentModificationDateKey]

        for volume in inspector.mountedVolumes() {
            let receiptsURL = URL(fileURLWithPath: volume.path, isDirectory: true)
                .appendingPathComponent("_ingest_receipts", isDirectory: true)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: receiptsURL.path, isDirectory: &isDirectory),
                  isDirectory.boolValue,
                  let values = try? receiptsURL.resourceValues(forKeys: keys),
                  let modifiedAt = values.contentModificationDate else {
                continue
            }

            if let currentMatch = bestMatch {
                if modifiedAt > currentMatch.modifiedAt {
                    bestMatch = (volume.path, modifiedAt)
                }
            } else {
                bestMatch = (volume.path, modifiedAt)
            }
        }

        return bestMatch?.path
    }
}

