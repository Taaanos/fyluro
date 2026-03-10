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

    public init(cameraLabel: String, fileCount: Int) {
        self.cameraLabel = cameraLabel
        self.fileCount = fileCount
    }
}

public struct CameraCardAssessment: Equatable, Sendable {
    public let cameraLabel: String
    public let mixedCameraDetected: Bool
    public let totalCandidates: Int
    public let knownCameraFileCount: Int
    public let unknownCameraFileCount: Int
    public let distribution: [CameraDistributionEntry]

    public init(
        cameraLabel: String,
        mixedCameraDetected: Bool,
        totalCandidates: Int,
        knownCameraFileCount: Int,
        unknownCameraFileCount: Int,
        distribution: [CameraDistributionEntry]
    ) {
        self.cameraLabel = cameraLabel
        self.mixedCameraDetected = mixedCameraDetected
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
    public static let mixedLabel = "mixed-camera"

    public init() {}

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
        }

        let label = formattedLabel(make: make, model: model, serial: serial)
        return CameraInference(
            cameraLabel: label,
            make: make,
            model: model,
            serial: serial
        )
    }

    public func assessCard(candidates: [MediaCandidate]) -> CameraCardAssessment {
        let grouped = candidates
            .map(infer(for:))
            .reduce(into: [String: Int]()) { counts, inference in
                counts[inference.cameraLabel, default: 0] += 1
            }

        let distribution = grouped.map { label, count in
            return CameraDistributionEntry(
                cameraLabel: label,
                fileCount: count
            )
        }.sorted { lhs, rhs in
            if lhs.fileCount != rhs.fileCount {
                return lhs.fileCount > rhs.fileCount
            }
            return lhs.cameraLabel < rhs.cameraLabel
        }

        let knownDistribution = distribution.filter { $0.cameraLabel != Self.unknownLabel }
        let mixed = knownDistribution.count > 1
        let knownCount = knownDistribution.map(\.fileCount).reduce(0, +)
        let unknownCount = grouped[Self.unknownLabel] ?? 0
        let dominantLabel = knownDistribution.first?.cameraLabel ?? Self.unknownLabel

        return CameraCardAssessment(
            cameraLabel: mixed ? Self.mixedLabel : dominantLabel,
            mixedCameraDetected: mixed,
            totalCandidates: candidates.count,
            knownCameraFileCount: knownCount,
            unknownCameraFileCount: unknownCount,
            distribution: distribution
        )
    }

    private func formattedLabel(make: String?, model: String?, serial: String?) -> String {
        let normalizedModel = slug(model)
        let normalizedMake = slug(make)
        let normalizedSerial = stableSerialToken(serial)

        var segments: [String] = []
        if let normalizedModel {
            segments.append(normalizedModel)
        } else if let normalizedMake {
            segments.append(normalizedMake)
        }

        if let normalizedSerial {
            segments.append("sn")
            segments.append(normalizedSerial)
        }

        if segments.isEmpty {
            return Self.unknownLabel
        }

        return segments.joined(separator: "-")
    }

    private func stableSerialToken(_ serial: String?) -> String? {
        guard let normalized = slug(serial), !normalized.isEmpty else {
            return nil
        }

        let tokenLength = 8
        if normalized.count <= tokenLength {
            return normalized
        }

        return String(normalized.suffix(tokenLength))
    }

    private func slug(_ value: String?) -> String? {
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
