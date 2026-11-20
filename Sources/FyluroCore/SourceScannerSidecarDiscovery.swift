import Foundation

struct SourceScannerSidecarDiscovery {
    private let fileManager: FileManager
    private let rootContext: SourceScannerRootContext
    private let traversal: SourceScannerTraversal

    init(
        fileManager: FileManager,
        rootContext: SourceScannerRootContext,
        traversal: SourceScannerTraversal
    ) {
        self.fileManager = fileManager
        self.rootContext = rootContext
        self.traversal = traversal
    }

    func discover(
        for mediaURL: URL,
        siblingURLCache: inout [String: [URL]]
    ) throws -> [MediaSidecar] {
        let directoryPath = mediaURL.deletingLastPathComponent().standardizedFileURL.path
        let siblingURLs: [URL]
        if let cached = siblingURLCache[directoryPath] {
            siblingURLs = cached
        } else {
            siblingURLs = (try? fileManager.contentsOfDirectory(
                at: mediaURL.deletingLastPathComponent(),
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            siblingURLCache[directoryPath] = siblingURLs
        }

        let sidecarURLs = MediaSidecarSupport.discoverSidecarURLs(
            for: mediaURL,
            fileManager: fileManager,
            siblingURLs: siblingURLs
        )

        return try sidecarURLs.compactMap { sidecarURL in
            let standardized = sidecarURL.standardizedFileURL
            let values = try standardized.resourceValues(forKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .isReadableKey,
                .fileSizeKey,
                .contentModificationDateKey,
                .creationDateKey,
            ])

            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                return nil
            }
            guard values.isReadable != false else {
                return nil
            }
            guard let fileSize = values.fileSize else {
                return nil
            }

            let relativePath = try traversal.normalizeRelativePath(
                url: standardized,
                canonicalSourceRootURL: rootContext.canonicalSourceRootURL,
                sourceRootComponents: rootContext.sourceRootComponents
            )

            return MediaSidecar(
                absolutePath: standardized.path,
                relativePath: relativePath,
                sizeBytes: Int64(fileSize),
                mtime: values.contentModificationDate ?? Date(timeIntervalSince1970: 0),
                creationDate: values.creationDate,
                fileExtension: standardized.pathExtension.lowercased()
            )
        }
    }
}
