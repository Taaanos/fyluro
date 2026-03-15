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
                StripIPhoneLensVariantSuffixRule(),
                StripDJIManufacturerPrefixRule(),
            ]
        )
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
