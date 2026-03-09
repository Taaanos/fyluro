import Foundation

struct CameraInference {
    let cameraLabel: String
    let confidence: Double
    let make: String?
    let model: String?
    let serial: String?
}

struct CameraDistributionEntry {
    let cameraLabel: String
    let fileCount: Int
    let averageConfidence: Double
}

struct CameraCardAssessment {
    let cameraLabel: String
    let confidence: Double
    let mixedCameraDetected: Bool
    let warning: String?
    let sampleSize: Int
    let totalCandidates: Int
    let distribution: [CameraDistributionEntry]
}

struct CameraLabeler {
    private static let unknownLabel = "unknown-camera"
    private static let mixedLabel = "mixed-camera"
    private static let maxSampleSize = 24

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
            confidence: confidence(make: make, model: model, serial: serial),
            make: make,
            model: model,
            serial: serial
        )
    }

    func assessCard(candidates: [MediaCandidate]) -> CameraCardAssessment {
        let sampledCandidates = sample(candidates: candidates, maxSampleSize: Self.maxSampleSize)
        let sampledInferences = sampledCandidates.map(infer(for:))

        var grouped: [String: [CameraInference]] = [:]
        for inference in sampledInferences where inference.cameraLabel != Self.unknownLabel {
            grouped[inference.cameraLabel, default: []].append(inference)
        }

        let distribution = grouped.map { label, values in
            let avgConfidence = values.map(\.confidence).reduce(0, +) / Double(values.count)
            return CameraDistributionEntry(
                cameraLabel: label,
                fileCount: values.count,
                averageConfidence: avgConfidence
            )
        }.sorted { lhs, rhs in
            if lhs.fileCount != rhs.fileCount {
                return lhs.fileCount > rhs.fileCount
            }
            return lhs.cameraLabel < rhs.cameraLabel
        }

        guard let dominant = distribution.first else {
            return CameraCardAssessment(
                cameraLabel: Self.unknownLabel,
                confidence: 0.2,
                mixedCameraDetected: false,
                warning: nil,
                sampleSize: sampledCandidates.count,
                totalCandidates: candidates.count,
                distribution: []
            )
        }

        let secondCount = distribution.dropFirst().first?.fileCount ?? 0
        let knownCount = distribution.map(\.fileCount).reduce(0, +)
        let mixed = distribution.count > 1 && secondCount >= 2 && Double(secondCount) / Double(max(1, knownCount)) >= 0.2

        if mixed {
            return CameraCardAssessment(
                cameraLabel: Self.mixedLabel,
                confidence: 0.35,
                mixedCameraDetected: true,
                warning: "Mixed camera metadata detected in sampled files.",
                sampleSize: sampledCandidates.count,
                totalCandidates: candidates.count,
                distribution: distribution
            )
        }

        let confidence = min(0.99, (Double(dominant.fileCount) / Double(max(1, knownCount))) * dominant.averageConfidence)
        return CameraCardAssessment(
            cameraLabel: dominant.cameraLabel,
            confidence: confidence,
            mixedCameraDetected: false,
            warning: nil,
            sampleSize: sampledCandidates.count,
            totalCandidates: candidates.count,
            distribution: distribution
        )
    }

    private func sample(candidates: [MediaCandidate], maxSampleSize: Int) -> [MediaCandidate] {
        guard candidates.count > maxSampleSize else {
            return candidates
        }

        let photos = candidates.filter { $0.mediaType == .photo }
        let videos = candidates.filter { $0.mediaType == .video }
        let baseline = maxSampleSize / 2

        let photoTarget = min(photos.count, baseline)
        let videoTarget = min(videos.count, baseline)
        var sampled = spreadSample(of: photos, count: photoTarget) + spreadSample(of: videos, count: videoTarget)

        let remainder = maxSampleSize - sampled.count
        if remainder > 0 {
            let photoSet = Set(sampled.filter { $0.mediaType == .photo }.map(\.absolutePath))
            let videoSet = Set(sampled.filter { $0.mediaType == .video }.map(\.absolutePath))
            let remainingPool = photos.filter { !photoSet.contains($0.absolutePath) } + videos.filter { !videoSet.contains($0.absolutePath) }
            sampled += spreadSample(of: remainingPool, count: min(remainder, remainingPool.count))
        }

        return sampled.sorted { lhs, rhs in
            if lhs.relativePath != rhs.relativePath {
                return lhs.relativePath < rhs.relativePath
            }
            return lhs.absolutePath < rhs.absolutePath
        }
    }

    private func spreadSample(of input: [MediaCandidate], count: Int) -> [MediaCandidate] {
        guard count > 0, !input.isEmpty else {
            return []
        }

        if count == 1 {
            return [input[input.count / 2]]
        }

        guard count < input.count else {
            return input
        }

        var output: [MediaCandidate] = []
        let lastIndex = input.count - 1
        for index in 0..<count {
            let ratio = Double(index) / Double(count - 1)
            let candidateIndex = Int((ratio * Double(lastIndex)).rounded())
            output.append(input[candidateIndex])
        }

        var deduplicated: [MediaCandidate] = []
        var seen: Set<String> = []
        for candidate in output {
            if seen.insert(candidate.absolutePath).inserted {
                deduplicated.append(candidate)
            }
        }
        if deduplicated.count == count {
            return deduplicated
        }

        for candidate in input where deduplicated.count < count {
            if seen.insert(candidate.absolutePath).inserted {
                deduplicated.append(candidate)
            }
        }

        return deduplicated
    }

    private func confidence(make: String?, model: String?, serial: String?) -> Double {
        let base: Double
        if model != nil, serial != nil {
            base = 0.98
        } else if make != nil, model != nil {
            base = 0.9
        } else if model != nil {
            base = 0.82
        } else if make != nil {
            base = 0.65
        } else {
            base = 0.2
        }
        return base
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
