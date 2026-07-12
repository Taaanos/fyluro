import XCTest
@testable import RollKeepCore

final class CameraIdentityLabelNormalizerTests: XCTestCase {
    private let normalizer = CameraIdentityLabelNormalizer()

    func testReturnsNilForMissingModel() {
        XCTAssertNil(normalizer.normalizedModelIdentifier(forLabeling: nil))
        XCTAssertNil(normalizer.normalizedModelIdentifier(forLabeling: "   "))
    }

    func testNormalizesIPhoneModelWithApplePrefixAndLensSuffix() {
        XCTAssertEqual(
            normalizer.normalizedModelIdentifier(forLabeling: "Apple iPhone 15 Pro 48mm"),
            "iPhone 15 Pro"
        )
    }

    func testNormalizesIPhoneModelWithLensSuffixWithoutApplePrefix() {
        XCTAssertEqual(
            normalizer.normalizedModelIdentifier(forLabeling: "iPhone 15 Pro 24mm"),
            "iPhone 15 Pro"
        )
    }

    func testNormalizesDJIManufacturerPrefixFromModel() {
        XCTAssertEqual(
            normalizer.normalizedModelIdentifier(forLabeling: "DJI Mini4 Pro"),
            "Mini4 Pro"
        )
        XCTAssertEqual(
            normalizer.normalizedModelIdentifier(forLabeling: "DJI Mini3 Pro"),
            "Mini3 Pro"
        )
        XCTAssertEqual(
            normalizer.normalizedModelIdentifier(forLabeling: "dji-mini3 pro"),
            "mini3 pro"
        )
        XCTAssertEqual(
            normalizer.normalizedModelIdentifier(forLabeling: "dji_mini3 pro"),
            "mini3 pro"
        )
        XCTAssertEqual(
            normalizer.normalizedModelIdentifier(forLabeling: "DJI OsmoAction6"),
            "OsmoAction6"
        )
    }

    func testPreservesNonIPhoneModelStrings() {
        XCTAssertEqual(
            normalizer.normalizedModelIdentifier(forLabeling: "Sony FX3"),
            "Sony FX3"
        )
        XCTAssertEqual(
            normalizer.normalizedModelIdentifier(forLabeling: "Apple Vision Pro"),
            "Apple Vision Pro"
        )
    }

    func testDefaultRegistryExposesNamedRules() {
        XCTAssertEqual(
            CameraModelLabelRuleRegistry.default.rules.map { $0.id },
            [
                "strip-iphone-lens-variant-suffix",
                "strip-dji-manufacturer-prefix",
            ]
        )
    }

    func testAppliesCustomRegistryRulesInOrder() {
        let customNormalizer = CameraIdentityLabelNormalizer(
            ruleRegistry: CameraModelLabelRuleRegistry(
                rules: [
                    AppendSuffixRule(id: "first", suffix: "-a"),
                    AppendSuffixRule(id: "second", suffix: "-b"),
                ]
            )
        )

        XCTAssertEqual(
            customNormalizer.normalizedModelIdentifier(forLabeling: "camera-model"),
            "camera-model-a-b"
        )
    }
}

private struct AppendSuffixRule: CameraModelLabelNormalizationRule {
    let id: String
    let suffix: String

    func apply(to model: String) -> String {
        model + suffix
    }
}
