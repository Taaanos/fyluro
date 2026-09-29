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
        CameraModelLabelRuleRegistry(rules: [MapKnownModelCodeToProductNameRule()] + postCatalogRules)
    }

    /// Everything that runs after the user-catalog lookup. Exposed separately
    /// so the Settings folder preview applies exactly the same rules a real
    /// scan applies to a catalog name.
    public static var postCatalogRules: [any CameraModelLabelNormalizationRule] {
        [
            StripIPhoneLensVariantSuffixRule(),
            StripDJIManufacturerPrefixRule(),
        ]
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
///
/// The mapping itself is user data, not logic: a flat `{"CODE": "Name"}` JSON
/// file the app writes and the engine only reads (ROL-6 Section 6, "User
/// camera catalog"). It ships empty.
public struct MapKnownModelCodeToProductNameRule: CameraModelLabelNormalizationRule {
    public let id: String = "map-known-model-code-to-product-name"

    private let modelCodeMap: [String: String]

    /// `modelCodeMap` is injectable for testing. The default re-reads the
    /// user's catalog file on every construction (never cached), so a catalog
    /// edit takes effect on the next scan without any invalidation. Keys must
    /// already be normalized (see `CameraCatalogCodeNormalization`).
    public init(modelCodeMap: [String: String] = CameraUserCatalogReader().loadEntries()) {
        self.modelCodeMap = modelCodeMap
    }

    public func apply(to model: String) -> String {
        modelCodeMap[CameraCatalogCodeNormalization.normalize(model)] ?? model
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
