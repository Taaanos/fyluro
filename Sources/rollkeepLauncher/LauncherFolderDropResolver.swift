import Foundation

enum LauncherFolderDropResolution: Equatable {
    case folder(String)
    case rejected(String)
}

enum LauncherFolderDropResolver {
    static func resolve(_ urls: [URL]) -> LauncherFolderDropResolution {
        guard let url = urls.first else {
            return .rejected("Could not read the dropped item.")
        }

        let canonicalPath = canonicalPath(for: url)

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: canonicalPath, isDirectory: &isDirectory) else {
            return .rejected("That item no longer exists.")
        }

        if isDirectory.boolValue {
            return .folder(canonicalPath)
        }

        return .rejected("Drop a folder, not a file.")
    }

    private static func canonicalPath(for url: URL) -> String {
        url.standardizedFileURL
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
    }
}
