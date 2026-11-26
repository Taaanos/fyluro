import Foundation
import FyluroCore
import SwiftUI

struct LauncherDetectedCamera: Equatable, Identifiable {
    let rawModelCode: String
    var id: String { CameraCatalogCodeNormalization.normalize(rawModelCode) }
}

struct LauncherSavedCameraLabel: Equatable, Identifiable {
    let code: String
    let name: String
    var id: String { code }
}

@MainActor
final class LauncherCameraCatalogStore: ObservableObject {
    enum CatalogFileHealth: Equatable {
        case healthy
        case malformed(warning: String)
        case recovered(notice: String)

        var loadWarning: String? {
            if case let .malformed(warning) = self {
                return warning
            }
            return nil
        }

        var recoveryNotice: String? {
            if case let .recovered(notice) = self {
                return notice
            }
            return nil
        }
    }

    @Published private(set) var entries: [String: String] = [:]
    @Published private(set) var detectedCameras: [LauncherDetectedCamera] = []
    @Published private(set) var fileHealth: CatalogFileHealth = .healthy
    @Published private(set) var saveError: String?
    @Published private(set) var revision = 0
    @Published private(set) var isEnabled: Bool

    var loadWarning: String? {
        fileHealth.loadWarning
    }

    var recoveryNotice: String? {
        fileHealth.recoveryNotice
    }

    private let remembering: LauncherCameraCatalogRemembering
    private let preference: any LauncherCameraLabelsPreferring

    init(
        remembering: LauncherCameraCatalogRemembering = LauncherCameraCatalogFileStore(),
        preference: any LauncherCameraLabelsPreferring = LauncherCameraLabelsPreference()
    ) {
        self.remembering = remembering
        self.preference = preference
        self.isEnabled = preference.isEnabled
        applyLoadResult(remembering.load())
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        preference.isEnabled = enabled
        isEnabled = enabled
        revision += 1
    }

    var savedLabels: [LauncherSavedCameraLabel] {
        entries
            .map { LauncherSavedCameraLabel(code: $0.key, name: $0.value) }
            .sorted {
                let byName = $0.name.localizedCaseInsensitiveCompare($1.name)
                return byName == .orderedSame ? $0.code < $1.code : byName == .orderedAscending
            }
    }

    var unmappedDetectedCameras: [LauncherDetectedCamera] {
        detectedCameras.filter { entries[$0.id] == nil }
    }

    func name(forCode code: String) -> String? {
        guard isEnabled else { return nil }
        return entries[CameraCatalogCodeNormalization.normalize(code)]
    }

    func reload() {
        let previous = entries
        applyLoadResult(remembering.load())
        if entries != previous {
            revision += 1
        }
    }

    func updateDetectedCameras(from summaries: [LauncherSourceCameraSummary]) {
        var seen = Set<String>()
        var detected: [LauncherDetectedCamera] = []
        for summary in summaries where !summary.isUnknown {
            guard let raw = summary.rawModelCode else { continue }
            let camera = LauncherDetectedCamera(rawModelCode: raw)
            if seen.insert(camera.id).inserted {
                detected.append(camera)
            }
        }

        if detected != detectedCameras {
            detectedCameras = detected
        }
    }

    func folderLabel(forName name: String) -> String? {
        CameraLabeler.folderLabel(forCatalogName: name)
    }

    func validationMessage(code: String, name: String) -> String? {
        if CameraCatalogCodeNormalization.normalize(code).isEmpty {
            return "Enter the camera code."
        }
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Enter a name."
        }
        if folderLabel(forName: name) == nil {
            return "Use at least one letter or number (A–Z, 0–9). Other characters are omitted from folder names."
        }
        return nil
    }

    /// Other saved codes whose name resolves to the same folder. Allowed on purpose: one camera
    /// can write different model codes (for example from another recording app), and the user
    /// gives them one name. The UI shows a note (ROL-6 section 6).
    func codesSharingFolder(code: String, name: String) -> [String] {
        guard let folder = folderLabel(forName: name) else { return [] }
        let key = CameraCatalogCodeNormalization.normalize(code)
        return entries
            .filter { $0.key != key && folderLabel(forName: $0.value) == folder }
            .map(\.key)
            .sorted()
    }

    @discardableResult
    func save(code: String, name: String) -> Bool {
        guard validationMessage(code: code, name: name) == nil else { return false }

        let key = CameraCatalogCodeNormalization.normalize(code)
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard entries[key] != trimmedName else { return true }

        var updated = entries
        updated[key] = trimmedName
        return persist(updated)
    }

    @discardableResult
    func delete(code: String) -> Bool {
        let key = CameraCatalogCodeNormalization.normalize(code)
        guard entries[key] != nil else { return true }

        var updated = entries
        updated.removeValue(forKey: key)
        return persist(updated)
    }

    private func persist(_ updated: [String: String]) -> Bool {
        do {
            let movedAside = try remembering.save(updated)
            entries = updated
            saveError = nil
            if let movedAside {
                fileHealth = .recovered(notice: "The unreadable catalog file was kept as \(movedAside.lastPathComponent).")
            } else if case .malformed = fileHealth {
                fileHealth = .healthy
            }
            revision += 1
            return true
        } catch {
            saveError = "Could not save your camera labels: \(error.localizedDescription)"
            return false
        }
    }

    private func applyLoadResult(_ result: CameraUserCatalogLoadResult) {
        switch result {
        case .missing:
            entries = [:]
            if case .malformed = fileHealth {
                fileHealth = .healthy
            }
        case .loaded(let loaded):
            entries = loaded
            if case .malformed = fileHealth {
                fileHealth = .healthy
            }
        case .malformed:
            entries = [:]
            fileHealth = .malformed(
                warning: "Could not read CameraCatalog.json, so cameras use their camera codes as folder names. "
                    + "Fix or remove the file, or add a label below to keep a backup and start fresh."
            )
        }
    }
}
