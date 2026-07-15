import Foundation

public struct SourceScanner {
    private let fileManager: FileManager
    private let traversal: SourceScannerTraversal
    private let metadataResolver: SourceScannerMetadataResolver
    private let cameraLabeler = CameraLabeler()
    private let progressSnapshotCalculator = SourceScannerProgressSnapshotCalculator()

    public init(
        fileManager: FileManager = .default,
        photoMetadataExtractor: any PhotoMetadataExtracting = ImageIOPhotoMetadataExtractor(),
        videoMetadataExtractor: any VideoMetadataExtracting = AVFoundationVideoMetadataExtractor(),
        previewVideoMetadataExtractor: any VideoMetadataExtracting = AVFoundationVideoMetadataExtractor(embeddedFallbackMode: .structuredOnly),
        unknownLargeFileWarningThresholdBytes: Int64 = 64 * 1024 * 1024,
        forcedMissingCaptureDateRelativePaths: Set<String> = []
    ) {
        self.fileManager = fileManager
        self.traversal = SourceScannerTraversal(
            unknownLargeFileWarningThresholdBytes: unknownLargeFileWarningThresholdBytes
        )
        self.metadataResolver = SourceScannerMetadataResolver(
            photoMetadataExtractor: photoMetadataExtractor,
            videoMetadataExtractor: videoMetadataExtractor,
            previewVideoMetadataExtractor: previewVideoMetadataExtractor,
            forcedMissingCaptureDateRelativePaths: forcedMissingCaptureDateRelativePaths
        )
    }

    public func scan(
        sourceRoot: URL,
        mode: SourceScanMode = .deep,
        progress: (@Sendable (ScanProgressSnapshot) -> Void)? = nil
    ) throws -> ScanSummary {
        let rootContext = try traversal.makeRootContext(sourceRoot: sourceRoot, fileManager: fileManager)

        var candidates: [MediaCandidate] = []
        var errors: [ScanErrorRecord] = []
        var warnings: [ScanWarningRecord] = []
        var photoCount = 0
        var videoCount = 0
        var photoBytes: Int64 = 0
        var videoBytes: Int64 = 0
        var filesInTypicalLocations = 0
        var cameraLabelCounts: [String: Int] = [:]
        var siblingURLCache: [String: [URL]] = [:]
        var filesChecked = 0
        var bytesChecked: Int64 = 0
        var currentRelativePath: String?
        var progressState = SourceScannerProgressState()

        func emitProgressIfNeeded(force: Bool = false) {
            guard progressState.shouldEmit(filesChecked: filesChecked, force: force) else {
                return
            }

            progress?(progressSnapshotCalculator.makeProgressSnapshot(
                itemCount: photoCount + videoCount,
                filesChecked: filesChecked,
                photoCount: photoCount,
                videoCount: videoCount,
                photoBytes: photoBytes,
                videoBytes: videoBytes,
                bytesChecked: bytesChecked,
                totalBytes: photoBytes + videoBytes,
                currentRelativePath: currentRelativePath,
                cameraLabelCounts: cameraLabelCounts
            ))
        }

        guard let enumerator = fileManager.enumerator(
            at: rootContext.canonicalSourceRootURL,
            includingPropertiesForKeys: Array(SourceScannerTraversal.resourceKeys),
            options: [],
            errorHandler: { url, error in
                errors.append(ScanErrorRecord(path: url.path, message: error.localizedDescription))
                return true
            }
        ) else {
            throw SourceScannerError.unreadableSourceRoot(sourceRoot.path)
        }

        let sidecarDiscovery = SourceScannerSidecarDiscovery(
            fileManager: fileManager,
            rootContext: rootContext,
            traversal: traversal
        )

        while let url = enumerator.nextObject() as? URL {
            do {
                let resourceValues = try url.resourceValues(forKeys: SourceScannerTraversal.resourceKeys)
                let traversalDecision = try traversal.evaluate(
                    url: url,
                    resourceValues: resourceValues,
                    rootContext: rootContext
                )

                switch traversalDecision {
                case .skip:
                    continue
                case .skipDirectory:
                    enumerator.skipDescendants()
                    continue
                case let .skipSymbolicLink(relativePath):
                    // The enumerator does not follow symlinks, so the link target
                    // is never traversed. (We must not call skipDescendants() here:
                    // the enumerator does not treat the symlink as the current
                    // subdirectory, so it would skip the symlink's *parent*
                    // directory's remaining children.) Just record the skip.
                    traversal.recordSymbolicLinkSkippedWarning(
                        relativePath: relativePath,
                        warnings: &warnings
                    )
                    continue
                case let .include(resolvedURL, relativePath):
                    guard resourceValues.isReadable != false else {
                        errors.append(ScanErrorRecord(path: url.path, message: "File is not readable"))
                        continue
                    }

                    filesChecked += 1
                    currentRelativePath = relativePath

                    let fileSize = resourceValues.fileSize.map(Int64.init)
                    if let fileSize {
                        bytesChecked += fileSize
                    }

                    guard let mediaType = traversal.detectMediaType(for: resolvedURL) else {
                        if let fileSize {
                            traversal.maybeRecordUnknownLargeSkippedFileWarning(
                                relativePath: relativePath,
                                fileSize: fileSize,
                                warnings: &warnings
                            )
                        }
                        emitProgressIfNeeded()
                        continue
                    }

                    guard let fileSize else {
                        errors.append(ScanErrorRecord(path: url.path, message: "Unable to read file size"))
                        emitProgressIfNeeded()
                        continue
                    }

                    let mtime = resourceValues.contentModificationDate ?? Date(timeIntervalSince1970: 0)
                    let creationDate = resourceValues.creationDate
                    let metadata = metadataResolver.resolve(
                        mediaType: mediaType,
                        fileURL: resolvedURL,
                        relativePath: relativePath,
                        fallbackMtime: mtime,
                        mode: mode
                    )
                    let sidecars = try sidecarDiscovery.discover(
                        for: resolvedURL,
                        siblingURLCache: &siblingURLCache
                    )

                    let candidate = MediaCandidate(
                        absolutePath: resolvedURL.path,
                        relativePath: relativePath,
                        mediaType: mediaType,
                        sizeBytes: fileSize,
                        mtime: mtime,
                        creationDate: creationDate,
                        photoMetadata: metadata.photoMetadata,
                        videoMetadata: metadata.videoMetadata,
                        sidecars: sidecars
                    )
                    candidates.append(candidate)
                    let cameraLabel = cameraLabeler.infer(for: candidate).cameraLabel
                    cameraLabelCounts[cameraLabel, default: 0] += 1

                    switch mediaType {
                    case .photo:
                        photoCount += 1
                        photoBytes += fileSize
                    case .video:
                        videoCount += 1
                        videoBytes += fileSize
                    }

                    if traversal.isInTypicalMediaLocation(relativePath: relativePath) {
                        filesInTypicalLocations += 1
                    }

                    let detectedMediaCount = photoCount + videoCount
                    let reachedCandidateMilestone = detectedMediaCount == 1 || detectedMediaCount % 10 == 0
                    emitProgressIfNeeded(force: reachedCandidateMilestone)
                }
            } catch let sourceError as SourceScannerError {
                throw sourceError
            } catch {
                errors.append(ScanErrorRecord(path: url.path, message: error.localizedDescription))
            }
        }

        candidates.sort { lhs, rhs in
            let leftKey = lhs.relativePath.lowercased()
            let rightKey = rhs.relativePath.lowercased()
            if leftKey != rightKey {
                return leftKey < rightKey
            }
            if lhs.relativePath != rhs.relativePath {
                return lhs.relativePath < rhs.relativePath
            }
            return lhs.absolutePath < rhs.absolutePath
        }
        warnings.sort { lhs, rhs in
            let leftKey = lhs.path.lowercased()
            let rightKey = rhs.path.lowercased()
            if leftKey != rightKey {
                return leftKey < rightKey
            }
            return lhs.path < rhs.path
        }

        let summary = ScanSummary(
            candidates: candidates,
            photoCount: photoCount,
            videoCount: videoCount,
            photoBytes: photoBytes,
            videoBytes: videoBytes,
            filesInTypicalLocations: filesInTypicalLocations,
            filesOutsideTypicalLocations: candidates.count - filesInTypicalLocations,
            errors: errors,
            warnings: warnings
        )

        if !progressState.alreadyEmitted(forFilesChecked: filesChecked) {
            progress?(progressSnapshotCalculator.makeProgressSnapshot(
                itemCount: summary.candidates.count,
                filesChecked: filesChecked,
                photoCount: summary.photoCount,
                videoCount: summary.videoCount,
                photoBytes: summary.photoBytes,
                videoBytes: summary.videoBytes,
                bytesChecked: bytesChecked,
                totalBytes: summary.photoBytes + summary.videoBytes,
                currentRelativePath: currentRelativePath,
                cameraLabelCounts: cameraLabelCounts,
                cameraAssessmentOverride: summary.cameraAssessment
            ))
        }

        return summary
    }
}
