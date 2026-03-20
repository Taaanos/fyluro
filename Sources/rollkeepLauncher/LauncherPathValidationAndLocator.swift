import Foundation
import RollKeepCore

struct LauncherPathValidation {
    static func isValidSourcePath(_ path: String) -> Bool {
        isReadableDirectory(path)
    }

    static func isValidDestinationPath(_ path: String) -> Bool {
        guard isDirectory(path) else {
            return false
        }

        return FileManager.default.isWritableFile(atPath: path)
    }

    static func isValidPathPair(sourcePath: String, destinationPath: String) -> Bool {
        guard isValidSourcePath(sourcePath), isValidDestinationPath(destinationPath) else {
            return false
        }

        return DirectoryPathOverlapValidator.analyze(
            sourcePath: sourcePath,
            destinationPath: destinationPath
        ).isDisjoint
    }

    static func invalidPathPairMessage(sourcePath: String, destinationPath: String) -> String? {
        guard isValidSourcePath(sourcePath), isValidDestinationPath(destinationPath) else {
            return nil
        }

        let analysis = DirectoryPathOverlapValidator.analyze(
            sourcePath: sourcePath,
            destinationPath: destinationPath
        )
        guard !analysis.isDisjoint else {
            return nil
        }

        return "Source and destination must be different folders with no nesting."
    }

    private static func isReadableDirectory(_ path: String) -> Bool {
        guard isDirectory(path) else {
            return false
        }

        return FileManager.default.isReadableFile(atPath: path)
    }

    private static func isDirectory(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
        return exists && isDirectory.boolValue
    }
}

struct RollkeepCLIExecutableLocator {
    static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        launcherExecutableURL: URL? = Bundle.main.executableURL
    ) -> URL? {
        if let launcherExecutableURL {
            let sibling = launcherExecutableURL
                .deletingLastPathComponent()
                .appendingPathComponent("rollkeep", isDirectory: false)
            if isExecutable(path: sibling.path) {
                return sibling
            }
            return nil
        }

        if let override = environment["ROLLKEEP_CLI_PATH"],
           isExecutable(path: override) {
            return URL(fileURLWithPath: override)
        }

        if let pathValue = environment["PATH"] {
            for directory in pathValue.split(separator: ":").map(String.init) {
                let candidate = URL(fileURLWithPath: directory, isDirectory: true)
                    .appendingPathComponent("rollkeep", isDirectory: false)
                if isExecutable(path: candidate.path) {
                    return candidate
                }
            }
        }

        let fallbackCandidates = [
            "/opt/homebrew/bin/rollkeep",
            "/usr/local/bin/rollkeep",
            "/usr/bin/rollkeep",
        ]

        for candidate in fallbackCandidates where isExecutable(path: candidate) {
            return URL(fileURLWithPath: candidate)
        }

        return nil
    }

    private static func isExecutable(path: String) -> Bool {
        !path.isEmpty && FileManager.default.isExecutableFile(atPath: path)
    }
}
