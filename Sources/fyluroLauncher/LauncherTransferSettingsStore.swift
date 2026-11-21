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

enum LauncherParallelCopyLimit: Int, CaseIterable, Equatable, Sendable {
    case one = 1
    case two = 2

    init(clamping count: Int) {
        self = count == 2 ? .two : .one
    }
}

@MainActor
final class LauncherTransferSettingsStore: ObservableObject {
    enum DestinationMediumState: Equatable {
        case unselected
        case invalidPath(String)
        case detected(path: String, mediumType: DestinationMediumType)

        var path: String {
            switch self {
            case .unselected:
                return ""
            case let .invalidPath(path), let .detected(path, _):
                return path
            }
        }

        var mediumType: DestinationMediumType? {
            if case let .detected(_, mediumType) = self {
                return mediumType
            }
            return nil
        }
    }

    static let hddLockFootnote = "Locked to 1 for spinning disks to prevent slow head seeks."
    static let editableFootnote = "Default is 1. Use 2 only on a fast SSD. Changes apply to the next import."

    @Published private(set) var preferredCopyLimit: LauncherParallelCopyLimit
    @Published private(set) var destinationMediumState: DestinationMediumState = .unselected

    var preferredMaxParallelCopies: Int {
        preferredCopyLimit.rawValue
    }

    var destinationPath: String {
        destinationMediumState.path
    }

    var detectedMediumType: DestinationMediumType? {
        destinationMediumState.mediumType
    }

    private let memory: any LauncherParallelCopiesRemembering
    private let mediumDetector: any DestinationMediumDetecting

    init(
        memory: any LauncherParallelCopiesRemembering = LauncherParallelCopiesMemory(),
        mediumDetector: any DestinationMediumDetecting = IOKitDestinationMediumDetector()
    ) {
        self.memory = memory
        self.mediumDetector = mediumDetector
        preferredCopyLimit = LauncherParallelCopyLimit(clamping: memory.loadPreferredParallelCopies())
    }

    func setPreferredMaxParallelCopies(_ count: Int) {
        setPreferredCopyLimit(LauncherParallelCopyLimit(clamping: count))
    }

    func setPreferredCopyLimit(_ limit: LauncherParallelCopyLimit) {
        guard preferredCopyLimit != limit else {
            return
        }
        preferredCopyLimit = limit
        memory.savePreferredParallelCopies(limit.rawValue)
    }

    func updateDestinationPath(_ path: String) {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            destinationMediumState = .unselected
            return
        }
        guard LauncherPathValidation.isValidDestinationPath(trimmed) else {
            destinationMediumState = .invalidPath(trimmed)
            return
        }
        let detected = mediumDetector.detectMediumType(
            at: URL(fileURLWithPath: trimmed, isDirectory: true)
        )
        destinationMediumState = .detected(path: trimmed, mediumType: detected)
    }

    var isParallelCopiesLockedToSingleStream: Bool {
        if case .detected(_, mediumType: .rotationalHDD) = destinationMediumState {
            return true
        }
        return false
    }

    var effectiveMaxParallelCopies: Int {
        isParallelCopiesLockedToSingleStream ? LauncherParallelCopyLimit.one.rawValue : preferredCopyLimit.rawValue
    }

    func resolvedMaxParallelCopiesForRun(destinationPath path: String) -> Int {
        updateDestinationPath(path)
        return effectiveMaxParallelCopies
    }

    var detectedMediumDisplayText: String {
        switch destinationMediumState {
        case .unselected, .invalidPath:
            return "No destination selected"
        case .detected(_, .rotationalHDD):
            return "HDD"
        case .detected(_, .solidState):
            return "SSD"
        case .detected(_, .unknown):
            return "Unknown"
        }
    }

    var explanationFootnoteText: String {
        isParallelCopiesLockedToSingleStream ? Self.hddLockFootnote : Self.editableFootnote
    }
}
