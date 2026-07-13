import Foundation

/// Preflight check comparing the total bytes about to be copied against the
/// destination volume's available capacity, so a full disk is caught before
/// any file is written rather than partway through the copy phase.
enum DestinationSpaceChecker {
    struct InsufficientSpace {
        let availableBytes: Int64
        let requiredBytes: Int64
    }

    enum CheckOutcome {
        case sufficient
        case insufficient(InsufficientSpace)
        case unableToDetermine(String)
    }

    /// Fraction of `bytesToCopy` added on top as a safety margin.
    static let headroomFraction: Double = 0.05

    static func check(destinationURL: URL, bytesToCopy: Int64) -> CheckOutcome {
        let availableBytes: Int64
        do {
            let values = try destinationURL.resourceValues(forKeys: [
                .volumeAvailableCapacityForImportantUsageKey,
                .volumeAvailableCapacityKey,
            ])
            if let important = values.volumeAvailableCapacityForImportantUsage {
                availableBytes = important
            } else if let available = values.volumeAvailableCapacity {
                availableBytes = Int64(available)
            } else {
                return .unableToDetermine("Destination volume did not report available capacity")
            }
        } catch {
            return .unableToDetermine(error.localizedDescription)
        }

        let headroomBytes = Int64((Double(bytesToCopy) * headroomFraction).rounded(.up))
        let requiredBytes = bytesToCopy + headroomBytes

        guard availableBytes >= requiredBytes else {
            return .insufficient(InsufficientSpace(availableBytes: availableBytes, requiredBytes: requiredBytes))
        }
        return .sufficient
    }

    static func message(for insufficientSpace: InsufficientSpace, bytesToCopy: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        let headroomBytes = insufficientSpace.requiredBytes - bytesToCopy
        return "Destination has insufficient free space: need \(formatter.string(fromByteCount: insufficientSpace.requiredBytes)) "
            + "(\(formatter.string(fromByteCount: bytesToCopy)) of media + \(formatter.string(fromByteCount: headroomBytes)) headroom), "
            + "but only \(formatter.string(fromByteCount: insufficientSpace.availableBytes)) available."
    }
}
