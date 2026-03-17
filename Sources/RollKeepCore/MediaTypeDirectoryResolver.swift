import Foundation

public struct MediaTypeDirectoryResolver: @unchecked Sendable {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func directoryName(
        for mediaType: MediaType,
        parentDirectory: URL,
        knownFilePaths: [String] = []
    ) -> String {
        if let existing = existingDirectoryName(
            for: mediaType,
            parentDirectory: parentDirectory,
            knownFilePaths: knownFilePaths
        ) {
            return existing
        }

        return canonicalDirectoryName(for: mediaType)
    }

    public func resolvePath(_ path: String, knownFilePaths: [String] = []) -> String {
        let normalizedPath = normalizePath(path)
        let pathComponents = (normalizedPath as NSString).pathComponents

        guard normalizedPath.hasPrefix("/"), let filename = pathComponents.last else {
            return normalizedPath
        }

        var currentURL = URL(fileURLWithPath: pathComponents[0], isDirectory: true)
        let directoryComponents = Array(pathComponents.dropFirst().dropLast())
        let mediaDirectoryIndex = directoryComponents.indices.last(where: { componentIndex in
            mediaType(forDirectoryName: directoryComponents[componentIndex]) != nil
        })

        for (index, component) in directoryComponents.enumerated() {
            let resolvedComponent: String
            if mediaDirectoryIndex == index, let mediaType = mediaType(forDirectoryName: component) {
                resolvedComponent = directoryName(
                    for: mediaType,
                    parentDirectory: currentURL,
                    knownFilePaths: knownFilePaths
                )
            } else {
                resolvedComponent = component
            }

            currentURL = currentURL.appendingPathComponent(resolvedComponent, isDirectory: true)
        }

        return currentURL.appendingPathComponent(filename, isDirectory: false).path
    }

    private func existingDirectoryName(
        for targetMediaType: MediaType,
        parentDirectory: URL,
        knownFilePaths: [String]
    ) -> String? {
        if let filesystemMatch = existingDirectoryNameOnFilesystem(for: targetMediaType, parentDirectory: parentDirectory) {
            return filesystemMatch
        }

        let knownMatches = knownFilePaths.compactMap { filePath -> String? in
            let fileURL = URL(fileURLWithPath: normalizePath(filePath), isDirectory: false)
            let immediateParentDirectoryURL = fileURL.deletingLastPathComponent()
            let mediaDirectoryURL: URL
            let mediaDirectoryName: String

            if let directMediaType = mediaType(forDirectoryName: immediateParentDirectoryURL.lastPathComponent),
               directMediaType == targetMediaType {
                mediaDirectoryURL = immediateParentDirectoryURL
                mediaDirectoryName = immediateParentDirectoryURL.lastPathComponent
            } else {
                let possibleMediaDirectoryURL = immediateParentDirectoryURL.deletingLastPathComponent()
                guard let nestedMediaType = mediaType(forDirectoryName: possibleMediaDirectoryURL.lastPathComponent),
                      nestedMediaType == targetMediaType else {
                    return nil
                }

                mediaDirectoryURL = possibleMediaDirectoryURL
                mediaDirectoryName = possibleMediaDirectoryURL.lastPathComponent
            }

            let candidateParent = normalizePath(mediaDirectoryURL.deletingLastPathComponent().path)
            guard candidateParent == normalizePath(parentDirectory.path) else {
                return nil
            }

            return mediaDirectoryName
        }

        return preferredDirectoryName(
            from: knownMatches,
            canonicalName: canonicalDirectoryName(for: targetMediaType)
        )
    }

    private func existingDirectoryNameOnFilesystem(for mediaType: MediaType, parentDirectory: URL) -> String? {
        guard let entries = try? fileManager.contentsOfDirectory(atPath: parentDirectory.path) else {
            return nil
        }

        let canonicalName = canonicalDirectoryName(for: mediaType)
        let matches = entries.compactMap { entry -> String? in
            guard entry.caseInsensitiveCompare(canonicalName) == .orderedSame else {
                return nil
            }

            var isDirectory = ObjCBool(false)
            let candidatePath = parentDirectory.appendingPathComponent(entry, isDirectory: true).path
            guard fileManager.fileExists(atPath: candidatePath, isDirectory: &isDirectory), isDirectory.boolValue else {
                return nil
            }

            return entry
        }

        return preferredDirectoryName(from: matches, canonicalName: canonicalName)
    }

    private func preferredDirectoryName(from candidates: [String], canonicalName: String) -> String? {
        let uniqueCandidates = Array(Set(candidates)).sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }

        if uniqueCandidates.contains(canonicalName) {
            return canonicalName
        }

        let lowercaseName = canonicalName.lowercased()
        if uniqueCandidates.contains(lowercaseName) {
            return lowercaseName
        }

        return uniqueCandidates.first
    }

    private func canonicalDirectoryName(for mediaType: MediaType) -> String {
        switch mediaType {
        case .photo:
            return "Photos"
        case .video:
            return "Videos"
        }
    }

    private func mediaType(forDirectoryName directoryName: String) -> MediaType? {
        if directoryName.caseInsensitiveCompare("Photos") == .orderedSame {
            return .photo
        }

        if directoryName.caseInsensitiveCompare("Videos") == .orderedSame {
            return .video
        }

        return nil
    }

    private func normalizePath(_ path: String) -> String {
        URL(fileURLWithPath: path, isDirectory: false).standardizedFileURL.path
    }
}
