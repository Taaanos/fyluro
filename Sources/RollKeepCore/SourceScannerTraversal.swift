import Foundation

struct SourceScannerRootContext {
    let canonicalSourceRootURL: URL
    let sourceRootComponents: [String]
}

enum SourceScannerTraversalDecision {
    case skip
    case skipDirectory
    case skipSymbolicLink(relativePath: String)
    case include(resolvedURL: URL, relativePath: String)
}

struct SourceScannerTraversal {
    let unknownLargeFileWarningThresholdBytes: Int64

    init(unknownLargeFileWarningThresholdBytes: Int64) {
        self.unknownLargeFileWarningThresholdBytes = max(0, unknownLargeFileWarningThresholdBytes)
    }

    func makeRootContext(sourceRoot: URL, fileManager: FileManager) throws -> SourceScannerRootContext {
        let canonicalSourceRootURL = sourceRoot
            .resolvingSymlinksInPath()
            .standardizedFileURL
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: canonicalSourceRootURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              fileManager.isReadableFile(atPath: canonicalSourceRootURL.path)
        else {
            throw SourceScannerError.unreadableSourceRoot(sourceRoot.path)
        }

        return SourceScannerRootContext(
            canonicalSourceRootURL: canonicalSourceRootURL,
            sourceRootComponents: canonicalSourceRootURL.pathComponents
        )
    }

    func evaluate(
        url: URL,
        resourceValues: URLResourceValues,
        rootContext: SourceScannerRootContext
    ) throws -> SourceScannerTraversalDecision {
        if resourceValues.isSymbolicLink == true {
            // Never resolve the link target: it may point outside the source
            // root, and following it would both violate the source boundary and
            // import content the user did not intend. Compute the link's own
            // relative path from its (unresolved) location so it can be reported
            // and skipped without ever touching the target.
            let linkRelativePath = (try? normalizeRelativePath(
                url: url.standardizedFileURL,
                canonicalSourceRootURL: rootContext.canonicalSourceRootURL,
                sourceRootComponents: rootContext.sourceRootComponents
            )) ?? url.lastPathComponent
            return .skipSymbolicLink(relativePath: linkRelativePath)
        }

        let resolvedURL = url
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let relativePath = try normalizeRelativePath(
            url: resolvedURL,
            canonicalSourceRootURL: rootContext.canonicalSourceRootURL,
            sourceRootComponents: rootContext.sourceRootComponents
        )

        if shouldExclude(relativePath: relativePath, values: resourceValues) {
            return resourceValues.isDirectory == true ? .skipDirectory : .skip
        }

        guard resourceValues.isRegularFile == true else {
            return .skip
        }

        return .include(resolvedURL: resolvedURL, relativePath: relativePath)
    }

    func detectMediaType(for url: URL) -> MediaType? {
        let ext = url.pathExtension.lowercased()

        if Self.photoExtensions.contains(ext) {
            return .photo
        }

        if Self.videoExtensions.contains(ext) {
            return .video
        }

        if Self.audioExtensions.contains(ext) {
            return .audio
        }

        return nil
    }

    /// True when `audioURL` is a video-companion audio file (e.g. DJI Pocket
    /// 3's same-basename `.WAV` running alongside its `.MP4`) rather than a
    /// standalone recording. A plain filename check: same directory, same
    /// stem, sibling extension in `videoExtensions`. Only extensions in
    /// `videoCompanionAudioExtensions` are checked -- formats like `.m4a`
    /// have no known video-companion use case and always stand alone.
    func hasVideoSiblingPairing(for audioURL: URL, siblingURLs: [URL]) -> Bool {
        let ext = audioURL.pathExtension.lowercased()
        guard Self.videoCompanionAudioExtensions.contains(ext) else {
            return false
        }

        let audioStem = audioURL.deletingPathExtension().lastPathComponent.lowercased()
        let audioPath = audioURL.standardizedFileURL.path

        return siblingURLs.contains { sibling in
            let standardized = sibling.standardizedFileURL
            guard standardized.path != audioPath else {
                return false
            }
            guard Self.videoExtensions.contains(standardized.pathExtension.lowercased()) else {
                return false
            }
            return standardized.deletingPathExtension().lastPathComponent.lowercased() == audioStem
        }
    }

    func maybeRecordUnknownLargeSkippedFileWarning(
        relativePath: String,
        fileSize: Int64,
        warnings: inout [ScanWarningRecord]
    ) {
        guard fileSize >= unknownLargeFileWarningThresholdBytes else {
            return
        }
        guard warnings.count < Self.maxUnknownLargeFileWarnings else {
            return
        }
        guard isInTypicalMediaLocation(relativePath: relativePath) else {
            return
        }

        let ext = (relativePath as NSString).pathExtension.lowercased()
        guard !ext.isEmpty else {
            return
        }
        guard (2...8).contains(ext.count), ext.allSatisfy({ $0.isLetter || $0.isNumber }) else {
            return
        }
        guard !Self.photoExtensions.contains(ext),
              !Self.videoExtensions.contains(ext),
              !Self.audioExtensions.contains(ext),
              !MediaSidecarSupport.transferExtensions.contains(ext) else {
            return
        }
        guard !warnings.contains(where: { $0.path == relativePath }) else {
            return
        }

        warnings.append(ScanWarningRecord(
            path: relativePath,
            message: "Large skipped file has unknown extension .\(ext). Add it to video allowlist if this is camera media.",
            fileExtension: ext,
            sizeBytes: fileSize
        ))
    }

    func recordSymbolicLinkSkippedWarning(
        relativePath: String,
        warnings: inout [ScanWarningRecord]
    ) {
        let symbolicLinkWarningCount = warnings.reduce(into: 0) { count, warning in
            if warning.category == .symbolicLinkSkipped {
                count += 1
            }
        }
        guard symbolicLinkWarningCount < Self.maxSymbolicLinkWarnings else {
            return
        }
        guard !warnings.contains(where: {
            $0.category == .symbolicLinkSkipped && $0.path == relativePath
        }) else {
            return
        }

        warnings.append(ScanWarningRecord(
            path: relativePath,
            message: "Skipped symbolic link; symlinks are not imported and their targets are not followed.",
            fileExtension: "",
            sizeBytes: 0,
            category: .symbolicLinkSkipped
        ))
    }

    func normalizeRelativePath(
        url: URL,
        canonicalSourceRootURL: URL,
        sourceRootComponents: [String]
    ) throws -> String {
        let candidateComponents = url.pathComponents
        guard candidateComponents.starts(with: sourceRootComponents) else {
            throw SourceScannerError.sourceBoundaryViolation(
                path: url.path,
                sourceRoot: canonicalSourceRootURL.path
            )
        }

        let relativeComponents = candidateComponents.dropFirst(sourceRootComponents.count)
        return relativeComponents.joined(separator: "/")
    }

    func shouldExclude(relativePath: String, values: URLResourceValues) -> Bool {
        if values.isHidden == true {
            return true
        }

        if relativePath.isEmpty {
            return false
        }

        let components = relativePath.split(separator: "/").map(String.init)
        for component in components {
            if component.hasPrefix(".") {
                return true
            }

            if Self.systemEntries.contains(component.lowercased()) {
                return true
            }
        }

        return false
    }

    func isInTypicalMediaLocation(relativePath: String) -> Bool {
        let upperPath = relativePath.uppercased()
        return Self.typicalMediaRootPrefixes.contains(where: { upperPath.hasPrefix($0) })
    }

    static let resourceKeys: Set<URLResourceKey> = [
        .isDirectoryKey,
        .isRegularFileKey,
        .isSymbolicLinkKey,
        .isReadableKey,
        .isHiddenKey,
        .fileSizeKey,
        .contentModificationDateKey,
    ]

    static let systemEntries: Set<String> = [
        "$recycle.bin",
        "system volume information",
        "__macosx",
    ]

    static let photoExtensions: Set<String> = [
        "jpg", "jpeg", "png", "tif", "tiff", "heic", "heif", "gif", "bmp", "dng",
        "cr2", "cr3", "nef", "arw", "orf", "raf", "rw2", "srw", "pef", "x3f", "iiq", "gpr",
    ]

    static let videoExtensions: Set<String> = [
        "mov", "mp4", "m4v", "avi", "mpg", "mpeg", "mts", "m2ts", "mxf", "3gp", "3g2",
        "lrv", "mkv", "insv", "r3d", "braw", "crm", "ari", "cine", "ts", "webm",
    ]

    static let audioExtensions: Set<String> = [
        "wav", "mp3", "m4a", "aac", "caf", "aif", "aiff",
    ]

    /// Audio extensions that may also be a video's companion sidecar rather
    /// than a standalone recording (see `hasVideoSiblingPairing`).
    static let videoCompanionAudioExtensions: Set<String> = ["wav"]

    static let typicalMediaRootPrefixes: [String] = [
        "DCIM/",
        "PRIVATE/",
        "AVCHD/",
        "MP_ROOT/",
        "MISC/",
        "MOVIE/",
        "VIDEO/",
    ]

    private static let maxUnknownLargeFileWarnings = 50
    private static let maxSymbolicLinkWarnings = 50
}
