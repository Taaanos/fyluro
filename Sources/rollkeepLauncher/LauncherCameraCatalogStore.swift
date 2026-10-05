import Foundation
import RollKeepCore
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

/// Backs Settings > Camera Labels. Every edit saves immediately (no
/// draft/apply step), and `revision` bumps on any change so the main window
/// re-scans and refreshes its camera inventory labels.
@MainActor
final class LauncherCameraCatalogStore: ObservableObject {
    @Published private(set) var entries: [String: String] = [:]
    @Published private(set) var detectedCameras: [LauncherDetectedCamera] = []
    @Published private(set) var loadWarning: String?
    @Published private(set) var recoveryNotice: String?
    @Published private(set) var saveError: String?
    @Published private(set) var revision = 0

    private let remembering: LauncherCameraCatalogRemembering

    init(remembering: LauncherCameraCatalogRemembering = LauncherCameraCatalogFileStore()) {
        self.remembering = remembering
        applyLoadResult(remembering.load())
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
        entries[CameraCatalogCodeNormalization.normalize(code)]
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

    /// nil means the pair can be saved.
    func validationMessage(code: String, name: String) -> String? {
        if CameraCatalogCodeNormalization.normalize(code).isEmpty {
            return "Enter the camera code."
        }
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Enter a name."
        }
        if folderLabel(forName: name) == nil {
            return "Use at least one letter or number (A-Z, 0-9). Other characters are dropped from folder names."
        }
        let sharing = codesSharingFolder(code: code, name: name)
        if !sharing.isEmpty {
            return "Another camera already uses this name (\(sharing.joined(separator: ", "))). Names must be unique."
        }
        return nil
    }

    /// Other saved codes whose name resolves to the same folder. A name that
    /// another code already uses is not saved (ROL-6 section 6).
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
            loadWarning = nil
            if let movedAside {
                recoveryNotice = "The unreadable catalog file was kept as \(movedAside.lastPathComponent)."
            }
            revision += 1
            return true
        } catch {
            saveError = "Couldn't save your camera labels: \(error.localizedDescription)"
            return false
        }
    }

    private func applyLoadResult(_ result: CameraUserCatalogLoadResult) {
        switch result {
        case .missing:
            entries = [:]
            loadWarning = nil
        case .loaded(let loaded):
            entries = loaded
            loadWarning = nil
        case .malformed:
            entries = [:]
            loadWarning = "CameraCatalog.json couldn't be read, so cameras use their raw codes as folder names. "
                + "Fix or remove the file, or add a label below (the unreadable file is kept as a backup first)."
        }
    }
}
