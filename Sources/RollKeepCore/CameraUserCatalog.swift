import Foundation

public enum CameraCatalogCodeNormalization {
    public static func normalize(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }
}

public enum CameraUserCatalogFileLocation {
    /// Tests and fixture runs point this at a throwaway file so they never
    /// read the developer's real catalog.
    public static let environmentOverrideKey = "ROLLKEEP_CAMERA_CATALOG_PATH"

    public static func fileURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> URL {
        if let override = environment[environmentOverrideKey], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }

        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return base
            .appendingPathComponent("RollKeep", isDirectory: true)
            .appendingPathComponent("CameraCatalog.json", isDirectory: false)
    }
}

public enum CameraUserCatalogLoadResult: Equatable, Sendable {
    case missing
    case loaded([String: String])
    case malformed(String)

    /// Labeling always proceeds: a missing or unreadable catalog contributes
    /// nothing and the raw model code is used as the label.
    public var entries: [String: String] {
        if case .loaded(let entries) = self {
            return entries
        }
        return [:]
    }
}

/// Read-only view of the user's camera catalog (ROL-6 Section 6). The app is
/// the only writer; this type is what the engine and CLI use.
public struct CameraUserCatalogReader {
    public let fileURL: URL

    public init(fileURL: URL = CameraUserCatalogFileLocation.fileURL()) {
        self.fileURL = fileURL
    }

    public func load() -> CameraUserCatalogLoadResult {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return .missing
        } catch {
            return .malformed(error.localizedDescription)
        }

        let raw: [String: String]
        do {
            raw = try JSONDecoder().decode([String: String].self, from: data)
        } catch {
            return .malformed("not a valid {\"CODE\": \"Name\"} JSON object")
        }

        var entries: [String: String] = [:]
        entries.reserveCapacity(raw.count)
        for (code, name) in raw {
            let key = CameraCatalogCodeNormalization.normalize(code)
            let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty, !trimmedName.isEmpty else { continue }
            entries[key] = trimmedName
        }
        return .loaded(entries)
    }

    public func loadEntries() -> [String: String] {
        load().entries
    }
}
