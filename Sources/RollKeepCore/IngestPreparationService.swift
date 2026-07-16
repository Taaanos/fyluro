import Foundation

public struct IngestPreparation: Sendable {
    public let scanSummary: ScanSummary
    public let cameraInferenceByPath: [String: CameraInference]
    public let plan: DestinationPathPlanner.Plan?
    let cameraEvidenceByPath: [String: CameraIdentityEvidence]

    public init(
        scanSummary: ScanSummary,
        cameraInferenceByPath: [String: CameraInference],
        plan: DestinationPathPlanner.Plan?
    ) {
        self.init(
            scanSummary: scanSummary,
            cameraInferenceByPath: cameraInferenceByPath,
            plan: plan,
            cameraEvidenceByPath: [:]
        )
    }

    init(
        scanSummary: ScanSummary,
        cameraInferenceByPath: [String: CameraInference],
        plan: DestinationPathPlanner.Plan?,
        cameraEvidenceByPath: [String: CameraIdentityEvidence]
    ) {
        self.scanSummary = scanSummary
        self.cameraInferenceByPath = cameraInferenceByPath
        self.plan = plan
        self.cameraEvidenceByPath = cameraEvidenceByPath
    }

    public func cameraInference(for candidate: MediaCandidate) -> CameraInference {
        cameraInferenceByPath[candidate.absolutePath] ?? CameraInference(
            cameraLabel: CameraLabeler.unknownLabel,
            make: nil,
            model: nil,
            serial: nil
        )
    }

    public func cameraEvidencePayload(for candidate: MediaCandidate) -> [String: Any] {
        if let evidence = cameraEvidenceByPath[candidate.absolutePath] {
            return evidence.receiptPayload()
        }

        let fallbackInference = cameraInference(for: candidate)
        return CameraIdentityResolver().resolveResolvedIdentity(
            make: fallbackInference.make,
            makeSource: fallbackInference.make == nil ? nil : .unresolved,
            makeSelectionRule: "inference_fallback",
            model: fallbackInference.model,
            modelSource: fallbackInference.model == nil ? nil : .unresolved,
            modelSelectionRule: "inference_fallback",
            serial: fallbackInference.serial,
            serialSource: fallbackInference.serial == nil ? nil : .unresolved,
            serialSelectionRule: "inference_fallback"
        ).evidence.receiptPayload()
    }

    public var cameraAssessment: CameraCardAssessment {
        let counts = scanSummary.candidates.reduce(into: [String: Int]()) { grouped, candidate in
            let label = cameraInference(for: candidate).cameraLabel
            grouped[label, default: 0] += 1
        }

        let distribution = counts.map { label, count in
            CameraDistributionEntry(cameraLabel: label, fileCount: count)
        }.sorted { lhs, rhs in
            if lhs.fileCount != rhs.fileCount {
                return lhs.fileCount > rhs.fileCount
            }
            return lhs.cameraLabel < rhs.cameraLabel
        }

        let knownDistribution = distribution.filter { $0.cameraLabel != CameraLabeler.unknownLabel }
        let knownCount = knownDistribution.map(\.fileCount).reduce(0, +)
        let unknownCount = counts[CameraLabeler.unknownLabel] ?? 0

        return CameraCardAssessment(
            totalCandidates: scanSummary.candidates.count,
            knownCameraFileCount: knownCount,
            unknownCameraFileCount: unknownCount,
            distribution: distribution
        )
    }
}

public struct IngestPreparationService {
    private let sourceScanner: SourceScanner
    private let cameraLabeler: CameraLabeler
    private let destinationPathPlanner: DestinationPathPlanner

    public init(
        sourceScanner: SourceScanner = SourceScanner(),
        cameraLabeler: CameraLabeler = CameraLabeler(),
        destinationPathPlanner: DestinationPathPlanner = DestinationPathPlanner()
    ) {
        self.sourceScanner = sourceScanner
        self.cameraLabeler = cameraLabeler
        self.destinationPathPlanner = destinationPathPlanner
    }

    public func scan(
        sourceRoot: URL,
        mode: SourceScanMode = .deep,
        metadataCache: (any SourceScanMetadataCaching)? = nil,
        progress: (@Sendable (ScanProgressSnapshot) -> Void)? = nil
    ) throws -> IngestPreparation {
        let summary = try sourceScanner.scan(sourceRoot: sourceRoot, mode: mode, metadataCache: metadataCache, progress: progress)
        var cameraInferenceByPath: [String: CameraInference] = [:]
        var cameraEvidenceByPath: [String: CameraIdentityEvidence] = [:]
        for candidate in summary.candidates {
            let inference = cameraLabeler.infer(for: candidate)
            cameraInferenceByPath[candidate.absolutePath] = inference

            if let evidence = cameraEvidence(for: candidate) {
                cameraEvidenceByPath[candidate.absolutePath] = evidence
                continue
            }

            let fallbackEvidence = CameraIdentityResolver().resolveResolvedIdentity(
                make: inference.make,
                makeSource: inference.make == nil ? nil : .unresolved,
                makeSelectionRule: "inference_fallback",
                model: inference.model,
                modelSource: inference.model == nil ? nil : .unresolved,
                modelSelectionRule: "inference_fallback",
                serial: inference.serial,
                serialSource: inference.serial == nil ? nil : .unresolved,
                serialSelectionRule: "inference_fallback"
            ).evidence
            cameraEvidenceByPath[candidate.absolutePath] = fallbackEvidence
        }

        return IngestPreparation(
            scanSummary: summary,
            cameraInferenceByPath: cameraInferenceByPath,
            plan: nil,
            cameraEvidenceByPath: cameraEvidenceByPath
        )
    }

    public func prepare(
        sourceRoot: URL,
        destRoot: URL,
        sessionID: String,
        metadataCache: (any SourceScanMetadataCaching)? = nil,
        progress: (@Sendable (ScanProgressSnapshot) -> Void)? = nil,
        existingFinalFiles: [String: String?] = [:],
        filmModeOverride: FilmModeOverride? = nil
    ) throws -> IngestPreparation {
        var scanned = try scan(sourceRoot: sourceRoot, metadataCache: metadataCache, progress: progress)
        if let filmModeOverride {
            scanned = applyingFilmModeOverride(filmModeOverride, to: scanned)
        }
        let photoCompressionClassifier = PhotoCompressionClassifier()
        var photoCompressionBucketsByMediaPath: [String: PhotoCompressionBucket] = [:]
        for candidate in scanned.scanSummary.candidates where candidate.mediaType == .photo {
            photoCompressionBucketsByMediaPath[candidate.absolutePath] = photoCompressionClassifier.bucket(for: candidate)
        }
        var cameraInferenceByPath = scanned.cameraInferenceByPath
        var cameraEvidenceByPath = scanned.cameraEvidenceByPath
        var plannerInputs = scanned.scanSummary.candidates.map { candidate in
            DestinationPathPlanner.SourceFile(
                candidate: candidate,
                cameraLabel: scanned.cameraInference(for: candidate).cameraLabel,
                sourceHash: nil,
                photoCompressionBucketOverride: photoCompressionBucketsByMediaPath[candidate.absolutePath]
            )
        }
        var sidecarPathsSeen: Set<String> = []

        for candidate in scanned.scanSummary.candidates {
            let inference = scanned.cameraInference(for: candidate)
            for sidecar in candidate.sidecars {
                guard sidecarPathsSeen.insert(sidecar.absolutePath).inserted else {
                    continue
                }

                let sidecarCandidate = MediaCandidate(
                    absolutePath: sidecar.absolutePath,
                    relativePath: sidecar.relativePath,
                    mediaType: candidate.mediaType,
                    sizeBytes: sidecar.sizeBytes,
                    mtime: sidecar.mtime,
                    creationDate: sidecar.creationDate,
                    photoMetadata: candidate.mediaType == .photo ? candidate.photoMetadata : nil,
                    videoMetadata: candidate.mediaType == .video ? candidate.videoMetadata : nil,
                    sidecars: []
                )

                plannerInputs.append(DestinationPathPlanner.SourceFile(
                    candidate: sidecarCandidate,
                    cameraLabel: inference.cameraLabel,
                    sourceHash: nil,
                    photoCompressionBucketOverride: photoCompressionBucketsByMediaPath[candidate.absolutePath]
                ))
                cameraInferenceByPath[sidecar.absolutePath] = inference
                if let evidence = scanned.cameraEvidenceByPath[candidate.absolutePath] {
                    cameraEvidenceByPath[sidecar.absolutePath] = evidence
                }
            }
        }

        plannerInputs.sort { lhs, rhs in
            let leftKey = lhs.candidate.relativePath.lowercased()
            let rightKey = rhs.candidate.relativePath.lowercased()
            if leftKey != rightKey {
                return leftKey < rightKey
            }
            if lhs.candidate.relativePath != rhs.candidate.relativePath {
                return lhs.candidate.relativePath < rhs.candidate.relativePath
            }
            return lhs.candidate.absolutePath < rhs.candidate.absolutePath
        }

        let plan = destinationPathPlanner.plan(
            destRoot: destRoot,
            sessionID: sessionID,
            files: plannerInputs,
            existingFinalFiles: existingFinalFiles
        )

        return IngestPreparation(
            scanSummary: scanned.scanSummary,
            cameraInferenceByPath: cameraInferenceByPath,
            plan: plan,
            cameraEvidenceByPath: cameraEvidenceByPath
        )
    }

    private func cameraEvidence(for candidate: MediaCandidate) -> CameraIdentityEvidence? {
        if let photoEvidence = candidate.photoMetadata?.cameraEvidence {
            return photoEvidence
        }
        if let videoEvidence = candidate.videoMetadata?.cameraEvidence {
            return videoEvidence
        }
        return nil
    }

    /// Replaces scanned EXIF (typically the digitizing camera's misleading
    /// date/make/model) with the user-declared film-mode values for every
    /// photo candidate. Video candidates are left untouched.
    private func applyingFilmModeOverride(
        _ override: FilmModeOverride,
        to preparation: IngestPreparation
    ) -> IngestPreparation {
        let overriddenPhotoMetadata = PhotoMetadata(
            captureDateTime: override.captureDate,
            captureDateSource: .filmModeOverride,
            cameraMake: nil,
            cameraModel: override.camera,
            cameraSerial: nil
        )

        let overriddenCandidates = preparation.scanSummary.candidates.map { candidate -> MediaCandidate in
            guard candidate.mediaType == .photo else {
                return candidate
            }
            return MediaCandidate(
                absolutePath: candidate.absolutePath,
                relativePath: candidate.relativePath,
                mediaType: candidate.mediaType,
                sizeBytes: candidate.sizeBytes,
                mtime: candidate.mtime,
                creationDate: candidate.creationDate,
                photoMetadata: overriddenPhotoMetadata,
                videoMetadata: candidate.videoMetadata,
                sidecars: candidate.sidecars
            )
        }

        let overriddenSummary = ScanSummary(
            candidates: overriddenCandidates,
            photoCount: preparation.scanSummary.photoCount,
            videoCount: preparation.scanSummary.videoCount,
            photoBytes: preparation.scanSummary.photoBytes,
            videoBytes: preparation.scanSummary.videoBytes,
            filesInTypicalLocations: preparation.scanSummary.filesInTypicalLocations,
            filesOutsideTypicalLocations: preparation.scanSummary.filesOutsideTypicalLocations,
            errors: preparation.scanSummary.errors,
            warnings: preparation.scanSummary.warnings
        )

        var overriddenInferenceByPath = preparation.cameraInferenceByPath
        var overriddenEvidenceByPath = preparation.cameraEvidenceByPath
        for candidate in overriddenCandidates where candidate.mediaType == .photo {
            overriddenInferenceByPath[candidate.absolutePath] = cameraLabeler.infer(for: candidate)
            overriddenEvidenceByPath.removeValue(forKey: candidate.absolutePath)
        }

        return IngestPreparation(
            scanSummary: overriddenSummary,
            cameraInferenceByPath: overriddenInferenceByPath,
            plan: nil,
            cameraEvidenceByPath: overriddenEvidenceByPath
        )
    }
}
