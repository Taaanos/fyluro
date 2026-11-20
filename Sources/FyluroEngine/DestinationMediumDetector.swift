import Darwin
import Foundation
import IOKit

/// Storage medium classification for an ingest destination mount.
public enum DestinationMediumType: String, Equatable, Sendable {
    case rotationalHDD = "rotational_hdd"
    case solidState = "solid_state"
    case unknown = "unknown"
}

/// Resolves the underlying storage medium type for a destination URL.
public protocol DestinationMediumDetecting: Sendable {
    func detectMediumType(at destinationURL: URL) -> DestinationMediumType
}

/// Queries macOS IOKit `Device Characteristics` on the destination's mount device.
public struct IOKitDestinationMediumDetector: DestinationMediumDetecting {
    private static let deviceCharacteristicsKey = "Device Characteristics"
    private static let mediumTypeKey = "Medium Type"
    private static let rotationalValue = "Rotational"
    private static let solidStateValue = "Solid State"
    private static let rotationRateKey = "Rotation Rate"
    private static let maxAncestorVisits = 64

    public init() {}

    public func detectMediumType(at destinationURL: URL) -> DestinationMediumType {
        guard let existingPath = deepestExistingPath(for: destinationURL),
              let bsdName = bsdDeviceName(forExistingPath: existingPath)
        else {
            return .unknown
        }

        return detectMediumType(forBSDDeviceName: bsdName)
    }

    func detectMediumType(forBSDDeviceName bsdName: String) -> DestinationMediumType {
        guard let matching = IOBSDNameMatching(kIOMainPortDefault, 0, bsdName) else {
            return .unknown
        }
        let rootService = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard rootService != 0 else {
            return .unknown
        }

        // Breadth-first walk up kIOServicePlane so synthesized APFS volumes reach
        // their underlying physical store(s) and IOBlockStorageDriver characteristics.
        var queue: [io_registry_entry_t] = [rootService]
        var visited = 0
        var sawSolidState = false

        while !queue.isEmpty && visited < Self.maxAncestorVisits {
            let entry = queue.removeFirst()
            defer { IOObjectRelease(entry) }
            visited += 1

            if let characteristicsRef = IORegistryEntryCreateCFProperty(
                entry,
                Self.deviceCharacteristicsKey as CFString,
                kCFAllocatorDefault,
                0
            ) {
                let value = characteristicsRef.takeRetainedValue()
                if let characteristics = value as? [String: Any],
                   let medium = Self.classifyDeviceCharacteristics(characteristics)
                {
                    if medium == .rotationalHDD {
                        for remaining in queue {
                            IOObjectRelease(remaining)
                        }
                        return .rotationalHDD
                    }
                    if medium == .solidState {
                        sawSolidState = true
                    }
                }
            }

            var parentIterator: io_iterator_t = 0
            let status = IORegistryEntryGetParentIterator(entry, kIOServicePlane, &parentIterator)
            guard status == KERN_SUCCESS, parentIterator != 0 else {
                continue
            }
            defer { IOObjectRelease(parentIterator) }

            while true {
                let parent = IOIteratorNext(parentIterator)
                guard parent != 0 else { break }
                if queue.count + visited < Self.maxAncestorVisits {
                    queue.append(parent)
                } else {
                    IOObjectRelease(parent)
                }
            }
        }

        for remaining in queue {
            IOObjectRelease(remaining)
        }

        return sawSolidState ? .solidState : .unknown
    }

    /// Maps an IOKit `Device Characteristics` dictionary to a medium classification.
    static func classifyDeviceCharacteristics(_ characteristics: [String: Any]) -> DestinationMediumType? {
        if let mediumType = characteristics[mediumTypeKey] as? String {
            if mediumType == rotationalValue {
                return .rotationalHDD
            }
            if mediumType == solidStateValue {
                return .solidState
            }
        }

        if let rotationRate = (characteristics[rotationRateKey] as? NSNumber)?.intValue,
           rotationRate > 0
        {
            return .rotationalHDD
        }

        return nil
    }

    private func deepestExistingPath(for url: URL) -> String? {
        let fileManager = FileManager.default
        var candidate = url.standardizedFileURL
        while !fileManager.fileExists(atPath: candidate.path) {
            let parent = candidate.deletingLastPathComponent()
            if parent.path == candidate.path {
                return nil
            }
            candidate = parent
        }
        return candidate.path
    }

    private func bsdDeviceName(forExistingPath path: String) -> String? {
        var fs = statfs()
        guard statfs(path, &fs) == 0 else {
            return nil
        }

        let mountFrom = withUnsafeBytes(of: fs.f_mntfromname) { rawBuffer in
            let bytes = rawBuffer.prefix { $0 != 0 }
            return String(decoding: bytes, as: UTF8.self)
        }

        let devPrefix = "/dev/"
        guard mountFrom.hasPrefix(devPrefix) else {
            return nil
        }
        let bsdName = String(mountFrom.dropFirst(devPrefix.count))
        return bsdName.isEmpty ? nil : bsdName
    }
}
