import Foundation

public protocol CameraModelLabelNormalizationRule {
    var id: String { get }
    func apply(to model: String) -> String
}

public struct CameraModelLabelRuleRegistry {
    public let rules: [any CameraModelLabelNormalizationRule]

    public init(rules: [any CameraModelLabelNormalizationRule]) {
        self.rules = rules
    }

    public static var `default`: CameraModelLabelRuleRegistry {
        CameraModelLabelRuleRegistry(
            rules: [
                MapKnownModelCodeToProductNameRule(),
                StripIPhoneLensVariantSuffixRule(),
                StripDJIManufacturerPrefixRule(),
            ]
        )
    }
}

/// Some vendors write two different vocabularies for the same physical
/// camera depending on media type: a bare internal model code (what photo
/// EXIF `Model` always contains, and what a video vendor-atom decoder may
/// also produce) versus a retail product name (what some video metadata
/// exposes instead). Without reconciling these, photos and videos from the
/// same camera land in different camera folders. Maps known bare codes to
/// their product name so both media types converge on one label regardless
/// of which vocabulary a given file happened to use.
public struct MapKnownModelCodeToProductNameRule: CameraModelLabelNormalizationRule {
    public let id: String = "map-known-model-code-to-product-name"

    // Confirmed against real camera output:
    // - DJI: EXIF `Model` on photos is the bare code; the code<->name pairing
    //   is confirmed via the hidden `ExifIFD:UniqueCameraModel` tag, e.g.
    //   "DJI AC003 OsmoAction4". Product name here already excludes the "DJI"
    //   prefix, which StripDJIManufacturerPrefixRule also strips from the
    //   "DJI <name>" form some video paths produce, so both converge.
    // - Samsung: `SM-A546B` (photo/video model number) has no shared string
    //   with `Galaxy A54 5G` (photo-only marketing name) at all -- mapped by
    //   hand since there's no way to derive one from the other.
    private static let knownModelCodes: [String: String] = [
        "AC003": "OsmoAction4",
        "AC006": "OsmoAction6",
        "FC8482": "Mini4 Pro",
        "PP-101": "OsmoPocket3",
        "SM-A546B": "Galaxy A54 5G",
    ]

    public init() {}

    public func apply(to model: String) -> String {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        return Self.knownModelCodes[trimmed.uppercased()] ?? model
    }
}

public struct StripIPhoneLensVariantSuffixRule: CameraModelLabelNormalizationRule {
    public let id: String = "strip-iphone-lens-variant-suffix"

    public init() {}

    // Collapse iPhone lens-specific model variants to a stable device-family label key.
    public func apply(to model: String) -> String {
        let withoutApplePrefix = model.replacingOccurrences(
            of: #"^\s*apple\s+"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )

        guard withoutApplePrefix.range(
            of: #"^iphone\s"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil else {
            return model
        }

        return withoutApplePrefix.replacingOccurrences(
            of: #"\s+\d{2,3}mm$"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
    }
}

public struct StripDJIManufacturerPrefixRule: CameraModelLabelNormalizationRule {
    public let id: String = "strip-dji-manufacturer-prefix"

    public init() {}

    public func apply(to model: String) -> String {
        let stripped = model.replacingOccurrences(
            of: #"^\s*dji[\s_-]+(.+?)\s*$"#,
            with: "$1",
            options: [.regularExpression, .caseInsensitive]
        ).trimmingCharacters(in: .whitespacesAndNewlines)

        return stripped.isEmpty ? model : stripped
    }
}

public struct CameraIdentityLabelNormalizer {
    private let ruleRegistry: CameraModelLabelRuleRegistry

    public init(ruleRegistry: CameraModelLabelRuleRegistry = .default) {
        self.ruleRegistry = ruleRegistry
    }

    public func normalizedModelIdentifier(forLabeling model: String?) -> String? {
        guard let raw = model?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }

        var normalized = raw
        for rule in ruleRegistry.rules {
            normalized = rule.apply(to: normalized)
        }

        let trimmed = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? raw : trimmed
    }
}
