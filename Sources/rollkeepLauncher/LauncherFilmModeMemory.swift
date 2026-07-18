import Foundation
import RollKeepCore

struct LauncherFilmModeHistoryEntry: Codable, Equatable {
    var camera: String
    var filmStock: String?
    var iso: Int?
    var creator: String?
    var copyright: String?
    var lens: String?
    var scannerSetup: String?
}

protocol LauncherFilmModeRemembering {
    func loadHistory() -> [LauncherFilmModeHistoryEntry]
    func recordApplied(camera: String, filmStock: String?, iso: Int?, creator: String?, copyright: String?, lens: String?, scannerSetup: String?)
}

/// Most-recently-used list of previously applied Film Mode combos, keyed by
/// camera name. Doubles as the prefill source (first entry) and the camera
/// autocomplete source (all `camera` values), and is the natural extension
/// point for named presets later without a data-model migration.
struct LauncherFilmModeMemory: LauncherFilmModeRemembering {
    let userDefaults: UserDefaults
    let key: String
    let maxEntries: Int

    init(
        userDefaults: UserDefaults = .standard,
        key: String = "rollkeep.launcher.filmMode.history",
        maxEntries: Int = 20
    ) {
        self.userDefaults = userDefaults
        self.key = key
        self.maxEntries = maxEntries
    }

    func loadHistory() -> [LauncherFilmModeHistoryEntry] {
        guard let data = userDefaults.data(forKey: key),
              let entries = try? JSONDecoder().decode([LauncherFilmModeHistoryEntry].self, from: data)
        else {
            return []
        }
        return entries
    }

    func recordApplied(camera: String, filmStock: String?, iso: Int?, creator: String?, copyright: String?, lens: String?, scannerSetup: String?) {
        let trimmedCamera = camera.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCamera.isEmpty else {
            return
        }

        var entries = loadHistory()
        entries.removeAll { $0.camera.caseInsensitiveCompare(trimmedCamera) == .orderedSame }
        entries.insert(
            LauncherFilmModeHistoryEntry(
                camera: trimmedCamera,
                filmStock: filmStock,
                iso: iso,
                creator: creator,
                copyright: copyright,
                lens: lens,
                scannerSetup: scannerSetup
            ),
            at: 0
        )
        if entries.count > maxEntries {
            entries.removeLast(entries.count - maxEntries)
        }

        guard let data = try? JSONEncoder().encode(entries) else {
            return
        }
        userDefaults.set(data, forKey: key)
    }
}
