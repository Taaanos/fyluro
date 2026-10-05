import Foundation

public struct CameraInference: Equatable, Sendable {
    public let cameraLabel: String
    public let make: String?
    public let model: String?
    public let serial: String?

    public init(cameraLabel: String, make: String?, model: String?, serial: String?) {
        self.cameraLabel = cameraLabel
        self.make = make
        self.model = model
        self.serial = serial
    }
}

public struct CameraDistributionEntry: Equatable, Sendable {
    public let cameraLabel: String
    public let fileCount: Int
    /// First raw model string (as the camera wrote it) seen for this label,
    /// so the app can offer to name the camera. `nil` for `unknown-camera`,
    /// audio, and the live-progress path, which doesn't track it.
    public let rawModelCode: String?
    /// Every distinct raw model string seen for this label, in the order first seen.
    /// One label can cover files that write different model strings (for example `iPhone 15 Pro`
    /// and `Apple iPhone 15 Pro 13mm`). The user catalog matches the exact string, so the app
    /// needs all of them to offer a name for each. Empty when `rawModelCode` is `nil`.
    public let rawModelCodes: [String]

    public init(cameraLabel: String, fileCount: Int, rawModelCode: String? = nil, rawModelCodes: [String]? = nil) {
        self.cameraLabel = cameraLabel
        self.fileCount = fileCount
        self.rawModelCode = rawModelCode
        self.rawModelCodes = rawModelCodes ?? rawModelCode.map { [$0] } ?? []
    }
}

public struct CameraCardAssessment: Equatable, Sendable {
    public let totalCandidates: Int
    public let knownCameraFileCount: Int
    public let unknownCameraFileCount: Int
    public let distribution: [CameraDistributionEntry]

    public init(
        totalCandidates: Int,
        knownCameraFileCount: Int,
        unknownCameraFileCount: Int,
        distribution: [CameraDistributionEntry]
    ) {
        self.totalCandidates = totalCandidates
        self.knownCameraFileCount = knownCameraFileCount
        self.unknownCameraFileCount = unknownCameraFileCount
        self.distribution = distribution
    }

    public var detectedCameraCount: Int {
        distribution.filter { $0.cameraLabel != CameraLabeler.unknownLabel }.count
    }
}

public struct CameraLabeler {
    public static let unknownLabel = "unknown-camera"
    private let identityNormalizer: CameraIdentityLabelNormalizer

    public init(identityNormalizer: CameraIdentityLabelNormalizer = CameraIdentityLabelNormalizer()) {
        self.identityNormalizer = identityNormalizer
    }

    /// Fixed camera-level label for standalone audio. Audio is not subject
    /// to device/camera inference in v1 (ROL-6 Section 6) -- getting files
    /// into the correct chronological bucket matters now; per-device
    /// labeling may be introduced later.
    public static let audioLabel = "audio"

    public func infer(for candidate: MediaCandidate) -> CameraInference {
        let make: String?
        let model: String?
        let serial: String?

        switch candidate.mediaType {
        case .photo:
            make = candidate.photoMetadata?.cameraMake
            model = candidate.photoMetadata?.cameraModel
            serial = candidate.photoMetadata?.cameraSerial
        case .video:
            make = candidate.videoMetadata?.cameraMake
            model = candidate.videoMetadata?.cameraModel
            serial = candidate.videoMetadata?.cameraSerial
        case .audio:
            return CameraInference(cameraLabel: Self.audioLabel, make: nil, model: nil, serial: nil)
        }

        let label = formattedLabel(make: make, model: model)
        return CameraInference(
            cameraLabel: label,
            make: make,
            model: model,
            serial: serial
        )
    }

    public func assessCard(candidates: [MediaCandidate]) -> CameraCardAssessment {
        Self.assessment(from: candidates.map(infer(for:)))
    }

    /// Single place that turns per-file inferences into the card inventory,
    /// shared by the scan summary and ingest preparation so they can't drift.
    static func assessment(from inferences: [CameraInference]) -> CameraCardAssessment {
        var counts: [String: Int] = [:]
        var rawModelByLabel: [String: String] = [:]
        var rawModelsByLabel: [String: [String]] = [:]
        for inference in inferences {
            counts[inference.cameraLabel, default: 0] += 1

            guard inference.cameraLabel != unknownLabel,
                  inference.cameraLabel != audioLabel,
                  let rawModel = inference.model?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !rawModel.isEmpty
            else {
                continue
            }
            if rawModelByLabel[inference.cameraLabel] == nil {
                rawModelByLabel[inference.cameraLabel] = rawModel
            }
            if !(rawModelsByLabel[inference.cameraLabel] ?? []).contains(rawModel) {
                rawModelsByLabel[inference.cameraLabel, default: []].append(rawModel)
            }
        }

        let distribution = counts.map { label, count in
            CameraDistributionEntry(
                cameraLabel: label,
                fileCount: count,
                rawModelCode: rawModelByLabel[label],
                rawModelCodes: rawModelsByLabel[label]
            )
        }.sorted { lhs, rhs in
            if lhs.fileCount != rhs.fileCount {
                return lhs.fileCount > rhs.fileCount
            }
            return lhs.cameraLabel < rhs.cameraLabel
        }

        let knownDistribution = distribution.filter { $0.cameraLabel != unknownLabel }
        let knownCount = knownDistribution.map(\.fileCount).reduce(0, +)
        let unknownCount = counts[unknownLabel] ?? 0

        return CameraCardAssessment(
            totalCandidates: inferences.count,
            knownCameraFileCount: knownCount,
            unknownCameraFileCount: unknownCount,
            distribution: distribution
        )
    }

    private func formattedLabel(make: String?, model: String?) -> String {
        let normalizedModel = Self.slug(identityNormalizer.normalizedModelIdentifier(forLabeling: model))
        let normalizedMake = Self.slug(make)

        var segments: [String] = []
        if let normalizedModel {
            segments.append(normalizedModel)
        } else if let normalizedMake {
            segments.append(normalizedMake)
        }

        if segments.isEmpty {
            return Self.unknownLabel
        }

        return segments.joined(separator: "-")
    }

    /// The folder label a camera gets when the user's catalog maps its model
    /// code to `name`: the same post-catalog rules and slugging a real scan
    /// applies. `nil` when nothing usable survives (e.g. a name made only of
    /// non-ASCII characters), which the catalog UI must reject.
    public static func folderLabel(forCatalogName name: String) -> String? {
        let normalizer = CameraIdentityLabelNormalizer(
            ruleRegistry: CameraModelLabelRuleRegistry(rules: CameraModelLabelRuleRegistry.postCatalogRules)
        )
        return slug(normalizer.normalizedModelIdentifier(forLabeling: name))
    }

    private static func slug(_ value: String?) -> String? {
        guard let value else {
            return nil
        }

        var scalarBuffer = String.UnicodeScalarView()
        scalarBuffer.reserveCapacity(value.unicodeScalars.count)
        for scalar in value.lowercased().unicodeScalars {
            if scalar.isASCII {
                scalarBuffer.append(scalar)
            }
        }

        let ascii = String(scalarBuffer)
        var output = ""
        output.reserveCapacity(ascii.count)
        var previousWasHyphen = false

        for scalar in ascii.unicodeScalars {
            let isAlphaNum =
                (scalar.value >= 48 && scalar.value <= 57) ||
                (scalar.value >= 97 && scalar.value <= 122)

            if isAlphaNum {
                output.unicodeScalars.append(scalar)
                previousWasHyphen = false
            } else if !previousWasHyphen {
                output.append("-")
                previousWasHyphen = true
            }
        }

        while output.first == "-" {
            output.removeFirst()
        }
        while output.last == "-" {
            output.removeLast()
        }

        return output.isEmpty ? nil : output
    }
}
