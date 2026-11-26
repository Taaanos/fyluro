import Foundation
import FyluroCore

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

        return "Source and destination must be different folders, and neither can be inside the other."
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
