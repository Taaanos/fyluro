import Foundation

public enum PathChronologicalLayout: String, CaseIterable, Sendable {
    case yearYearMonthCompact = "YYYY/YYYYMM"
    case yearMonthNested = "YYYY/MM"

    public static func parseCLIValue(_ value: String) -> PathChronologicalLayout? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        return Self.allCases.first { candidate in
            candidate.rawValue.caseInsensitiveCompare(trimmed) == .orderedSame
        }
    }
}

public enum PhotoCompressionBucket: String, CaseIterable, Sendable {
    case raw = "RAW"
    case nonRaw = "Non-RAW"
}

public struct PhotoCompressionClassifier: Sendable {
    public init() {}

    public static let rawExtensions: Set<String> = [
        "dng", "cr2", "cr3", "nef", "arw", "orf", "raf", "rw2", "srw", "pef", "x3f", "iiq", "gpr",
    ]

    public func bucket(for candidate: MediaCandidate) -> PhotoCompressionBucket {
        bucket(forRelativePath: candidate.relativePath)
    }

    public func bucket(forRelativePath relativePath: String) -> PhotoCompressionBucket {
        let ext = (relativePath as NSString).pathExtension.lowercased()
        return Self.rawExtensions.contains(ext) ? .raw : .nonRaw
    }
}

public struct ImportPathScheme: Equatable, Sendable {
    public let chronologicalLayout: PathChronologicalLayout
    public let includeCameraFolder: Bool
    public let splitPhotoCompression: Bool

    public static let `default` = ImportPathScheme(
        chronologicalLayout: .yearYearMonthCompact,
        includeCameraFolder: true,
        splitPhotoCompression: false
    )

    public init(
        chronologicalLayout: PathChronologicalLayout,
        includeCameraFolder: Bool,
        splitPhotoCompression: Bool
    ) {
        self.chronologicalLayout = chronologicalLayout
        self.includeCameraFolder = includeCameraFolder
        self.splitPhotoCompression = splitPhotoCompression
    }

    public var receiptPathSchemeString: String {
        let dated = pathTemplate(chronologicalComponent: chronologicalLayout.rawValue)
        let unsorted = pathTemplate(chronologicalComponent: "_unsorted")
        return "\(dated) ; \(unsorted)"
    }

    public func pathPrefixComponents(captureDate: Date?, cameraLabel: String) -> [String] {
        var components = chronologicalComponents(for: captureDate)
        if includeCameraFolder {
            components.append(cameraLabel)
        }
        return components
    }

    /// Audio's v1 flat-bucket path: `<chronological>/audio/<filename>`,
    /// unconditionally -- unlike Photos/Videos, this ignores
    /// `includeCameraFolder` and never appends a media-type subfolder (see
    /// ROL-6 Section 4 "Audio (v1 exception)").
    public func audioPathPrefixComponents(captureDate: Date?) -> [String] {
        chronologicalComponents(for: captureDate) + [CameraLabeler.audioLabel]
    }

    public func compressionDirectoryName(
        mediaType: MediaType,
        photoCompressionBucket: PhotoCompressionBucket?
    ) -> String? {
        guard splitPhotoCompression, mediaType == .photo else {
            return nil
        }

        return (photoCompressionBucket ?? .nonRaw).rawValue
    }

    private func pathTemplate(chronologicalComponent: String) -> String {
        var components: [String] = [chronologicalComponent]
        if includeCameraFolder {
            components.append("<Camera>")
        }
        components.append("<Photos|Videos>")
        if splitPhotoCompression {
            components.append("<RAW|Non-RAW (Photos)>")
        }
        components.append("<filename>")
        return components.joined(separator: "/")
    }

    private func chronologicalComponents(for captureDate: Date?) -> [String] {
        guard let captureDate else {
            return ["_unsorted"]
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .autoupdatingCurrent
        let components = calendar.dateComponents([.year, .month], from: captureDate)

        guard let year = components.year, let month = components.month else {
            return ["_unsorted"]
        }

        switch chronologicalLayout {
        case .yearYearMonthCompact:
            return [
                String(year),
                String(format: "%04d%02d", year, month),
            ]
        case .yearMonthNested:
            return [
                String(year),
                String(format: "%02d", month),
            ]
        }
    }
}
