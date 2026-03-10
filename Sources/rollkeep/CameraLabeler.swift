import Foundation

struct CameraInference {
    let cameraLabel: String
    let make: String?
    let model: String?
    let serial: String?
}

struct CameraDistributionEntry {
    let cameraLabel: String
    let fileCount: Int
}

struct CameraCardAssessment {
    let cameraLabel: String
    let mixedCameraDetected: Bool
    let totalCandidates: Int
    let knownCameraFileCount: Int
    let unknownCameraFileCount: Int
    let distribution: [CameraDistributionEntry]
}

struct CameraLabeler {
    private static let unknownLabel = "unknown-camera"
    private static let mixedLabel = "mixed-camera"

    func infer(for candidate: MediaCandidate) -> CameraInference {
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

    func assessCard(candidates: [MediaCandidate]) -> CameraCardAssessment {
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
