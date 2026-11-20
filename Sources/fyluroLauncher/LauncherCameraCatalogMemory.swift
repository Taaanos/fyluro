import Foundation
import FyluroCore

protocol LauncherCameraCatalogRemembering {
    func load() -> CameraUserCatalogLoadResult

    /// Returns the URL an unreadable existing file was moved to before the
    /// write, if there was one. Never overwrites an unreadable file in place.
    func save(_ entries: [String: String]) throws -> URL?
}

struct LauncherCameraCatalogFileStore: LauncherCameraCatalogRemembering {
    let fileURL: URL
    private let now: () -> Date

    init(
        fileURL: URL = CameraUserCatalogFileLocation.fileURL(),
        now: @escaping () -> Date = Date.init
    ) {
        self.fileURL = fileURL
        self.now = now
    }

    func load() -> CameraUserCatalogLoadResult {
        CameraUserCatalogReader(fileURL: fileURL).load()
    }

    func save(_ entries: [String: String]) throws -> URL? {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var movedAsideURL: URL?
        if case .malformed = load() {
            movedAsideURL = try moveUnreadableFileAside(fileManager: fileManager)
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(entries).write(to: fileURL, options: .atomic)
        return movedAsideURL
    }

    private func moveUnreadableFileAside(fileManager: FileManager) throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: now())

        let directory = fileURL.deletingLastPathComponent()
        let baseName = fileURL.deletingPathExtension().lastPathComponent
        let fileExtension = fileURL.pathExtension.isEmpty ? "" : ".\(fileURL.pathExtension)"

        var destination = directory.appendingPathComponent("\(baseName).corrupt-\(stamp)\(fileExtension)")
        var counter = 1
        while fileManager.fileExists(atPath: destination.path) {
            destination = directory.appendingPathComponent("\(baseName).corrupt-\(stamp)-\(counter)\(fileExtension)")
            counter += 1
        }

        try fileManager.moveItem(at: fileURL, to: destination)
        return destination
    }
}
