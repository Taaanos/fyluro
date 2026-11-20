import Foundation

struct StagingSessionCleanup {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    @discardableResult
    func removeIfPresent(path: String) throws -> Bool {
        let sessionURL = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        let sessionPath = sessionURL.path
        guard fileManager.fileExists(atPath: sessionPath) else {
            return false
        }

        try fileManager.removeItem(atPath: sessionPath)
        try removeStagingRootIfEmpty(sessionURL: sessionURL)
        return true
    }

    private func removeStagingRootIfEmpty(sessionURL: URL) throws {
        let stagingRootURL = sessionURL.deletingLastPathComponent()
        guard stagingRootURL.lastPathComponent == "_ingest_staging" else {
            return
        }
        guard fileManager.fileExists(atPath: stagingRootURL.path) else {
            return
        }

        let entries = try fileManager.contentsOfDirectory(atPath: stagingRootURL.path)
        if entries.isEmpty {
            try fileManager.removeItem(atPath: stagingRootURL.path)
        }
    }
}
