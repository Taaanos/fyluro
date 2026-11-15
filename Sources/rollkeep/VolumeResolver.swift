import Foundation
import RollKeepCore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

struct MountedVolume: Equatable {
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

protocol VolumeInspecting {
    func mountedVolumes() -> [MountedVolume]
    func likelyCardVolumes() -> [MountedVolume]
}

struct VolumeInspector: VolumeInspecting {
    let volumesRoot: URL
    let fileManager: FileManager
    private let removableHintProvider: (URL) -> Bool?

    init(
        volumesRoot: URL = URL(fileURLWithPath: "/Volumes", isDirectory: true),
        fileManager: FileManager = .default,
        removableHintProvider: @escaping (URL) -> Bool? = VolumeInspector.defaultRemovableHint(for:)
    ) {
        self.volumesRoot = volumesRoot
        self.fileManager = fileManager
        self.removableHintProvider = removableHintProvider
    }

    func mountedVolumes() -> [MountedVolume] {
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

        var volumes: [MountedVolume] = []
        volumes.reserveCapacity(volumeURLs.count)

        for volumeURL in volumeURLs {
            guard let values = try? volumeURL.resourceValues(forKeys: resourceKeys),
                  values.isDirectory == true,
                  values.isHidden != true else {
                continue
            }

            let standardizedPath = volumeURL.standardizedFileURL.path
            var dcimIsDir: ObjCBool = false
            let hasDCIM = fileManager.fileExists(
                atPath: volumeURL.appendingPathComponent("DCIM", isDirectory: true).path,
                isDirectory: &dcimIsDir
            ) && dcimIsDir.boolValue

            volumes.append(MountedVolume(
                path: standardizedPath,
                hasDCIM: hasDCIM,
                isRemovable: removableHintProvider(volumeURL)
            ))
        }

        return volumes.sorted(by: VolumeInspector.sortVolumes(_:_:))
    }

    func likelyCardVolumes() -> [MountedVolume] {
        mountedVolumes()
            .filter { $0.hasDCIM || $0.isRemovable == true }
            .sorted(by: VolumeInspector.sortLikelyVolumes(_:_:))
    }

    private static func sortVolumes(_ lhs: MountedVolume, _ rhs: MountedVolume) -> Bool {
        lhs.path < rhs.path
    }

    private static func sortLikelyVolumes(_ lhs: MountedVolume, _ rhs: MountedVolume) -> Bool {
        if lhs.heuristicScore != rhs.heuristicScore {
            return lhs.heuristicScore > rhs.heuristicScore
        }
        return lhs.path < rhs.path
    }

    static func defaultRemovableHint(for volumeURL: URL) -> Bool? {
        let keys: Set<URLResourceKey> = [.volumeIsRemovableKey]
        guard let values = try? volumeURL.resourceValues(forKeys: keys) else {
            return nil
        }
        return values.volumeIsRemovable
    }
}

enum VolumesWatcherError: Error, LocalizedError, Equatable {
    case timedOut(seconds: Int)

    var errorDescription: String? {
        switch self {
        case .timedOut(let seconds):
            return "Timed out waiting \(seconds)s for a new likely card mount."
        }
    }
}

protocol VolumesWatching {
    func waitForNewLikelyCard(timeout: TimeInterval?, baselinePaths: Set<String>) throws -> MountedVolume
}

struct VolumesWatcher: VolumesWatching {
    let inspector: VolumeInspecting
    let pollInterval: TimeInterval
    let sleep: (TimeInterval) -> Void
    let now: () -> Date

    init(
        inspector: VolumeInspecting = VolumeInspector(),
        pollInterval: TimeInterval = 0.5,
        sleep: @escaping (TimeInterval) -> Void = { duration in
            Thread.sleep(forTimeInterval: duration)
        },
        now: @escaping () -> Date = Date.init
    ) {
        self.inspector = inspector
        self.pollInterval = pollInterval
        self.sleep = sleep
        self.now = now
    }

    func waitForNewLikelyCard(timeout: TimeInterval?, baselinePaths: Set<String>) throws -> MountedVolume {
        let deadline = timeout.map { now().addingTimeInterval($0) }

        while true {
            let candidates = inspector.likelyCardVolumes()
            if let detected = candidates.first(where: { !baselinePaths.contains($0.path) }) {
                return detected
            }

            if let deadline, now() >= deadline {
                throw VolumesWatcherError.timedOut(seconds: Int(timeout ?? 0))
            }

            sleep(pollInterval)
        }
    }
}

protocol DestinationRemembering {
    func loadLastDestinationPath(from mountedVolumes: [MountedVolume]) -> String?
}

struct ReceiptBasedDestinationMemory: DestinationRemembering {
    let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func loadLastDestinationPath(from mountedVolumes: [MountedVolume]) -> String? {
        var bestMatch: (path: String, date: Date)?
        let keys: Set<URLResourceKey> = [.contentModificationDateKey]

        for volume in mountedVolumes {
            let receiptsDir = URL(fileURLWithPath: volume.path, isDirectory: true)
                .appendingPathComponent("_ingest_receipts", isDirectory: true)
            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: receiptsDir.path, isDirectory: &isDir),
                  isDir.boolValue else {
                continue
            }

            guard let values = try? receiptsDir.resourceValues(forKeys: keys),
                  let modifiedAt = values.contentModificationDate else {
                continue
            }

            if let current = bestMatch {
                if modifiedAt > current.date {
                    bestMatch = (volume.path, modifiedAt)
                }
            } else {
                bestMatch = (volume.path, modifiedAt)
            }
        }

        return bestMatch?.path
    }
}

enum VolumeResolverError: Error, LocalizedError, Equatable {
    case sourceNotProvidedAndNoCardDetected
    case sourceAmbiguous(paths: [String])
    case destinationNotProvidedAndNoRememberedMountedPath
    case destinationPickerCancelled
    case overlappingPaths(source: String, destination: String, relation: DirectoryPathRelation)

    var errorDescription: String? {
        switch self {
        case .sourceNotProvidedAndNoCardDetected:
            return "No source provided and no likely SD card detected under /Volumes."
        case .sourceAmbiguous(let paths):
            return "Multiple likely card mounts detected: \(paths.joined(separator: ", ")). Provide --source or use --pick-source."
        case .destinationNotProvidedAndNoRememberedMountedPath:
            return "No destination provided and no remembered mounted destination is available."
        case .destinationPickerCancelled:
            return "Destination selection cancelled."
        case .overlappingPaths(let source, let destination, let relation):
            return DirectoryPathPairAnalysis(
                sourcePath: source,
                destinationPath: destination,
                relation: relation
            ).overlapMessage
        }
    }
}

struct ResolvedIngestPaths {
    let sourceURL: URL
    let destinationURL: URL
    let sourceResolution: String
    let destinationResolution: String
}

struct VolumeResolver {
    let explicitSourcePath: String?
    let explicitDestinationPath: String?
    let detectTimeoutSeconds: Int
    let forceSourcePicker: Bool
    let forceDestinationPicker: Bool
    let inspector: VolumeInspecting
    let watcher: VolumesWatching
    let destinationMemory: DestinationRemembering
    let logger: StructuredLogger
    let isInteractive: Bool
    let readInput: () -> String?
    let writeOutput: (String) -> Void

    init(
        explicitSourcePath: String?,
        explicitDestinationPath: String?,
        detectTimeoutSeconds: Int = 60,
        forceSourcePicker: Bool = false,
        forceDestinationPicker: Bool = false,
        inspector: VolumeInspecting = VolumeInspector(),
        watcher: VolumesWatching? = nil,
        destinationMemory: DestinationRemembering = ReceiptBasedDestinationMemory(),
        logger: StructuredLogger,
        isInteractive: Bool = stdinIsTTY(),
        readInput: @escaping () -> String? = { readLine(strippingNewline: true) },
        writeOutput: @escaping (String) -> Void = { print($0) }
    ) {
        self.explicitSourcePath = explicitSourcePath
        self.explicitDestinationPath = explicitDestinationPath
        self.detectTimeoutSeconds = detectTimeoutSeconds
        self.forceSourcePicker = forceSourcePicker
        self.forceDestinationPicker = forceDestinationPicker
        self.inspector = inspector
        self.watcher = watcher ?? VolumesWatcher(inspector: inspector)
        self.destinationMemory = destinationMemory
        self.logger = logger
        self.isInteractive = isInteractive
        self.readInput = readInput
        self.writeOutput = writeOutput
    }

    func resolve() throws -> ResolvedIngestPaths {
        let sourceSelection = try resolveSource()
        let destinationSelection = try resolveDestination()
        let pairAnalysis = DirectoryPathOverlapValidator.analyze(
            sourcePath: sourceSelection.url.path,
            destinationPath: destinationSelection.url.path
        )

        guard pairAnalysis.isDisjoint else {
            throw VolumeResolverError.overlappingPaths(
                source: pairAnalysis.sourcePath,
                destination: pairAnalysis.destinationPath,
                relation: pairAnalysis.relation
            )
        }

        return ResolvedIngestPaths(
            sourceURL: sourceSelection.url,
            destinationURL: destinationSelection.url,
            sourceResolution: sourceSelection.resolution,
            destinationResolution: destinationSelection.resolution
        )
    }

    private func resolveSource() throws -> PathSelection {
        if let explicitSourcePath, !explicitSourcePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return PathSelection(
                url: URL(fileURLWithPath: explicitSourcePath, isDirectory: true).standardizedFileURL,
                resolution: "explicit"
            )
        }

        let likelyCards = inspector.likelyCardVolumes()
        if likelyCards.count == 1 {
            let card = likelyCards[0]
            if !forceSourcePicker || !isInteractive {
                logger.info("source_auto_detected", metadata: [
                    "path": card.path,
                    "reason": heuristicReason(for: card),
                ])
                return PathSelection(
                    url: URL(fileURLWithPath: card.path, isDirectory: true).standardizedFileURL,
                    resolution: "auto_detected_existing"
                )
            }

            let mounted = inspector.mountedVolumes()
            if let selected = pickPathInteractively(
                title: "Select source card mount",
                mounted: mounted,
                preferredPath: card.path,
                allowCustomPath: true
            ) {
                return PathSelection(
                    url: URL(fileURLWithPath: selected, isDirectory: true).standardizedFileURL,
                    resolution: "manual_picker"
                )
            }

            return PathSelection(
                url: URL(fileURLWithPath: card.path, isDirectory: true).standardizedFileURL,
                resolution: "auto_detected_existing"
            )
        }

        if likelyCards.count > 1 {
            if forceSourcePicker || isInteractive {
                let mounted = inspector.mountedVolumes()
                let preferred = likelyCards.first?.path
                if let selected = pickPathInteractively(
                    title: "Select source card mount",
                    mounted: mounted,
                    preferredPath: preferred,
                    allowCustomPath: true
                ) {
                    return PathSelection(
                        url: URL(fileURLWithPath: selected, isDirectory: true).standardizedFileURL,
                        resolution: "manual_picker"
                    )
                }
                throw VolumeResolverError.sourceAmbiguous(paths: likelyCards.map(\.path))
            }
            throw VolumeResolverError.sourceAmbiguous(paths: likelyCards.map(\.path))
        }

        let baseline = Set(inspector.mountedVolumes().map(\.path))
        let timeout = detectTimeoutSeconds > 0 ? TimeInterval(detectTimeoutSeconds) : nil

        if isInteractive {
            if let timeout {
                writeOutput("Waiting up to \(Int(timeout))s for an SD card mount under /Volumes...")
            } else {
                writeOutput("Waiting for an SD card mount under /Volumes...")
            }
        }

        do {
            let detected = try watcher.waitForNewLikelyCard(timeout: timeout, baselinePaths: baseline)
            logger.info("source_auto_detected_new_mount", metadata: [
                "path": detected.path,
                "reason": heuristicReason(for: detected),
            ])
            return PathSelection(
                url: URL(fileURLWithPath: detected.path, isDirectory: true).standardizedFileURL,
                resolution: "auto_detected_new_mount"
            )
        } catch {
            if isInteractive {
                let mounted = inspector.mountedVolumes()
                let selected = pickPathInteractively(
                    title: "No likely card auto-detected. Pick source manually",
                    mounted: mounted,
                    preferredPath: nil,
                    allowCustomPath: true
                )
                if let selected {
                    return PathSelection(
                        url: URL(fileURLWithPath: selected, isDirectory: true).standardizedFileURL,
                        resolution: "manual_picker"
                    )
                }
            }
            throw VolumeResolverError.sourceNotProvidedAndNoCardDetected
        }
    }

    private func resolveDestination() throws -> PathSelection {
        if let explicitDestinationPath, !explicitDestinationPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return PathSelection(
                url: URL(fileURLWithPath: explicitDestinationPath, isDirectory: true).standardizedFileURL,
                resolution: "explicit"
            )
        }

        let mounted = inspector.mountedVolumes()
        let mountedPaths = Set(mounted.map(\.path))
        let remembered = destinationMemory.loadLastDestinationPath(from: mounted)

        if !forceDestinationPicker, let remembered, mountedPaths.contains(remembered) {
            logger.info("destination_reused_from_memory", metadata: ["path": remembered])
            return PathSelection(
                url: URL(fileURLWithPath: remembered, isDirectory: true).standardizedFileURL,
                resolution: "remembered_mounted_path"
            )
        }

        guard isInteractive else {
            throw VolumeResolverError.destinationNotProvidedAndNoRememberedMountedPath
        }

        let selected = pickPathInteractively(
            title: "Select destination mount",
            mounted: mounted,
            preferredPath: remembered
        )
        guard let selected else {
            throw VolumeResolverError.destinationPickerCancelled
        }
        return PathSelection(
            url: URL(fileURLWithPath: selected, isDirectory: true).standardizedFileURL,
            resolution: "manual_picker"
        )
    }

    private func heuristicReason(for volume: MountedVolume) -> String {
        var reasons: [String] = []
        if volume.hasDCIM {
            reasons.append("dcim_present")
        }
        if volume.isRemovable == true {
            reasons.append("removable_hint")
        }
        return reasons.isEmpty ? "unknown" : reasons.joined(separator: "+")
    }

    private func pickPathInteractively(
        title: String,
        mounted: [MountedVolume],
        preferredPath: String?,
        allowCustomPath: Bool = true
    ) -> String? {
        writeOutput(title)

        for (index, volume) in mounted.enumerated() {
            writeOutput("  [\(index + 1)] \(volume.path) (\(heuristicReason(for: volume)))")
        }

        var prompt = "Enter number"
        if allowCustomPath {
            prompt += " or absolute path"
        }
        if let preferredPath {
            prompt += " (Enter for \(preferredPath))"
        }
        prompt += ": "

        while true {
            writeOutput(prompt)
            guard let rawInput = readInput() else {
                return preferredPath
            }
            let input = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)

            if input.isEmpty {
                return preferredPath
            }

            if let index = Int(input), index >= 1, index <= mounted.count {
                return mounted[index - 1].path
            }

            if allowCustomPath, input.hasPrefix("/") {
                return input
            }

            writeOutput("Invalid selection.")
        }
    }

}

private struct PathSelection {
    let url: URL
    let resolution: String
}

private func stdinIsTTY() -> Bool {
    isatty(STDIN_FILENO) == 1
}
