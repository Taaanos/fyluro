import Foundation

public struct IngestPreparation: Sendable {
    public let scanSummary: ScanSummary
    public let cameraInferenceByPath: [String: CameraInference]
    public let plan: DestinationPathPlanner.Plan?

    public init(
        scanSummary: ScanSummary,
        cameraInferenceByPath: [String: CameraInference],
        plan: DestinationPathPlanner.Plan?
    ) {
        self.scanSummary = scanSummary
        self.cameraInferenceByPath = cameraInferenceByPath
        self.plan = plan
    }

    public func cameraInference(for candidate: MediaCandidate) -> CameraInference {
        cameraInferenceByPath[candidate.absolutePath] ?? CameraInference(
            cameraLabel: CameraLabeler.unknownLabel,
            make: nil,
            model: nil,
            serial: nil
        )
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
        let mixed = knownDistribution.count > 1
        let knownCount = knownDistribution.map(\.fileCount).reduce(0, +)
        let unknownCount = counts[CameraLabeler.unknownLabel] ?? 0
        let dominantLabel = knownDistribution.first?.cameraLabel ?? CameraLabeler.unknownLabel

        return CameraCardAssessment(
            cameraLabel: mixed ? CameraLabeler.mixedLabel : dominantLabel,
            mixedCameraDetected: mixed,
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
        progress: (@Sendable (ScanProgressSnapshot) -> Void)? = nil
    ) throws -> IngestPreparation {
        let summary = try sourceScanner.scan(sourceRoot: sourceRoot, progress: progress)
        let cameraInferenceByPath = Dictionary(uniqueKeysWithValues: summary.candidates.map { candidate in
            (candidate.absolutePath, cameraLabeler.infer(for: candidate))
        })

        return IngestPreparation(
            scanSummary: summary,
            cameraInferenceByPath: cameraInferenceByPath,
            plan: nil
        )
    }

    public func prepare(
        sourceRoot: URL,
        destRoot: URL,
        sessionID: String,
        progress: (@Sendable (ScanProgressSnapshot) -> Void)? = nil,
        existingFinalFiles: [String: String?] = [:]
    ) throws -> IngestPreparation {
        let scanned = try scan(sourceRoot: sourceRoot, progress: progress)
        let plannerInputs = scanned.scanSummary.candidates.map { candidate in
            DestinationPathPlanner.SourceFile(
                candidate: candidate,
                cameraLabel: scanned.cameraInference(for: candidate).cameraLabel,
                sourceHash: nil
            )
        }

        let plan = destinationPathPlanner.plan(
            destRoot: destRoot,
            sessionID: sessionID,
            files: plannerInputs,
            existingFinalFiles: existingFinalFiles
        )

        return IngestPreparation(
            scanSummary: scanned.scanSummary,
            cameraInferenceByPath: scanned.cameraInferenceByPath,
            plan: plan
        )
    }
}
