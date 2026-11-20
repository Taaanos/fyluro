import Foundation
import FyluroEngine

protocol LauncherParallelCopiesRemembering: Sendable {
    func loadPreferredParallelCopies() -> Int
    func savePreferredParallelCopies(_ count: Int)
}

struct LauncherParallelCopiesMemory: LauncherParallelCopiesRemembering, @unchecked Sendable {
    static let defaultsKey = "fyluro.launcher.transfers.maxParallelCopies"

    private let userDefaults: UserDefaults
    private let key: String

    init(
        userDefaults: UserDefaults = .standard,
        key: String = LauncherParallelCopiesMemory.defaultsKey
    ) {
        self.userDefaults = userDefaults
        self.key = key
    }

    func loadPreferredParallelCopies() -> Int {
        let stored = userDefaults.integer(forKey: key)
        return Self.normalizedCount(stored)
    }

    func savePreferredParallelCopies(_ count: Int) {
        userDefaults.set(Self.normalizedCount(count), forKey: key)
    }

    static func normalizedCount(_ count: Int) -> Int {
        count == 2 ? 2 : 1
    }
}

/// Backs Settings > Transfers. Every change saves immediately and takes effect on the next run (ROL-6 I-10).
@MainActor
final class LauncherTransferSettingsStore: ObservableObject {
    static let hddLockFootnote = "Locked to 1 for spinning disks to prevent slow head seeks."
    static let editableFootnote = "Default is 1. Use 2 only on a fast SSD. Changes apply to the next import."

    @Published private(set) var preferredMaxParallelCopies: Int
    @Published private(set) var destinationPath: String = ""
    @Published private(set) var detectedMediumType: DestinationMediumType?

    private let memory: any LauncherParallelCopiesRemembering
    private let mediumDetector: any DestinationMediumDetecting

    init(
        memory: any LauncherParallelCopiesRemembering = LauncherParallelCopiesMemory(),
        mediumDetector: any DestinationMediumDetecting = IOKitDestinationMediumDetector()
    ) {
        self.memory = memory
        self.mediumDetector = mediumDetector
        preferredMaxParallelCopies = LauncherParallelCopiesMemory.normalizedCount(memory.loadPreferredParallelCopies())
    }

    func setPreferredMaxParallelCopies(_ count: Int) {
        let normalized = LauncherParallelCopiesMemory.normalizedCount(count)
        guard preferredMaxParallelCopies != normalized else {
            return
        }
        preferredMaxParallelCopies = normalized
        memory.savePreferredParallelCopies(normalized)
    }

    func updateDestinationPath(_ path: String) {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        destinationPath = trimmed
        guard !trimmed.isEmpty, LauncherPathValidation.isValidDestinationPath(trimmed) else {
            detectedMediumType = nil
            return
        }
        detectedMediumType = mediumDetector.detectMediumType(
            at: URL(fileURLWithPath: trimmed, isDirectory: true)
        )
    }

    var isParallelCopiesLockedToSingleStream: Bool {
        detectedMediumType == .rotationalHDD
    }

    var effectiveMaxParallelCopies: Int {
        isParallelCopiesLockedToSingleStream ? 1 : preferredMaxParallelCopies
    }

    func resolvedMaxParallelCopiesForRun(destinationPath path: String) -> Int {
        updateDestinationPath(path)
        return effectiveMaxParallelCopies
    }

    var detectedMediumDisplayText: String {
        switch detectedMediumType {
        case nil:
            return "No destination selected"
        case .rotationalHDD:
            return "HDD"
        case .solidState:
            return "SSD"
        case .unknown:
            return "Unknown"
        }
    }

    var explanationFootnoteText: String {
        isParallelCopiesLockedToSingleStream ? Self.hddLockFootnote : Self.editableFootnote
    }
}
