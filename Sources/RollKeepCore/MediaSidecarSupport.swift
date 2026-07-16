import Foundation

public struct MediaSidecar: Equatable, Sendable {
    public let absolutePath: String
    public let relativePath: String
    public let sizeBytes: Int64
    public let mtime: Date
    public let creationDate: Date?
    public let fileExtension: String

    public init(
        absolutePath: String,
        relativePath: String,
        sizeBytes: Int64,
        mtime: Date,
        creationDate: Date?,
        fileExtension: String
    ) {
        self.absolutePath = absolutePath
        self.relativePath = relativePath
        self.sizeBytes = sizeBytes
        self.mtime = mtime
        self.creationDate = creationDate
        self.fileExtension = fileExtension
    }
}

enum MediaSidecarSupport {
    static let transferExtensions: Set<String> = [
        "thm",
        "xmp",
        "aae",
        "xml",
        "srt",
        "cpi",
        "nksc",
        "dop",
        "pp3",
        "json",
        "wav",
    ]

    private static let metadataPriority: [String] = [
        "thm",
        "xmp",
        "xml",
        "cpi",
        "aae",
        "json",
        "srt",
        "nksc",
        "dop",
        "pp3",
    ]

    static func discoverSidecarURLs(
        for mediaURL: URL,
        fileManager: FileManager = .default,
        siblingURLs: [URL]? = nil
    ) -> [URL] {
        let siblings: [URL]
        if let siblingURLs {
            siblings = siblingURLs
        } else {
            siblings = (try? fileManager.contentsOfDirectory(
                at: mediaURL.deletingLastPathComponent(),
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            )) ?? []
        }

        let mediaPath = mediaURL.standardizedFileURL.path
        return siblings
            .filter { candidate in
                let standardized = candidate.standardizedFileURL
                guard standardized.path != mediaPath else {
                    return false
                }

                let ext = standardized.pathExtension.lowercased()
                guard transferExtensions.contains(ext) else {
                    return false
                }

                let values = try? standardized.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values?.isRegularFile == true, values?.isSymbolicLink != true else {
                    return false
                }

                return baseNameMatches(mediaURL: mediaURL, sidecarURL: standardized)
            }
            .sorted(by: sidecarOrder)
    }

    private static func baseNameMatches(mediaURL: URL, sidecarURL: URL) -> Bool {
        let mediaName = mediaURL.lastPathComponent.lowercased()
        let mediaStem = mediaURL.deletingPathExtension().lastPathComponent.lowercased()
        let sidecarStem = sidecarURL.deletingPathExtension().lastPathComponent.lowercased()

        if sidecarStem == mediaStem || sidecarStem == mediaName {
            return true
        }

        let sidecarExtension = sidecarURL.pathExtension.lowercased()
        if sidecarExtension == "xml" {
            return matchesSonyClipXMLVariant(mediaStem: mediaStem, sidecarStem: sidecarStem)
        }

        return false
    }

    // Sony clip XML often appends an M-index suffix (e.g. C3501M01.XML) to the clip stem.
    private static func matchesSonyClipXMLVariant(mediaStem: String, sidecarStem: String) -> Bool {
        guard sidecarStem.hasPrefix(mediaStem) else {
            return false
        }

        let suffix = String(sidecarStem.dropFirst(mediaStem.count))
        guard suffix.count == 3 || suffix.count == 4 else {
            return false
        }

        guard suffix.first == "m" else {
            return false
        }

        return suffix.dropFirst().allSatisfy(\.isNumber)
    }

    private static func sidecarOrder(lhs: URL, rhs: URL) -> Bool {
        let leftPriority = metadataPriorityIndex(lhs.pathExtension)
        let rightPriority = metadataPriorityIndex(rhs.pathExtension)
        if leftPriority != rightPriority {
            return leftPriority < rightPriority
        }

        let leftName = lhs.lastPathComponent.lowercased()
        let rightName = rhs.lastPathComponent.lowercased()
        if leftName != rightName {
            return leftName < rightName
        }

        return lhs.path < rhs.path
    }

    private static func metadataPriorityIndex(_ ext: String) -> Int {
        metadataPriority.firstIndex(of: ext.lowercased()) ?? metadataPriority.count
    }
}
