import XCTest
@testable import RollKeepCore

final class CameraIdentityLabelNormalizerTests: XCTestCase {
    // Seeded explicitly: the default registry reads the user's catalog file,
    // which is empty on a fresh install and machine-specific otherwise.
    private let normalizer = CameraIdentityLabelNormalizer(
        ruleRegistry: CameraModelLabelRuleRegistry(
            rules: [
                MapKnownModelCodeToProductNameRule(modelCodeMap: [
                    "AC003": "OsmoAction4",
                    "AC006": "OsmoAction6",
                    "FC8482": "Mini4 Pro",
                    "PP-101": "OsmoPocket3",
                    "SM-A546B": "Galaxy A54 5G",
                ]),
            ] + CameraModelLabelRuleRegistry.postCatalogRules
        )
    )

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
                "map-known-model-code-to-product-name",
                "strip-iphone-lens-variant-suffix",
                "strip-dji-manufacturer-prefix",
            ]
        )
    }

    /// Photos and videos from the same physical camera must land in the same
    /// camera folder even when they use different vocabularies for the
    /// model: photo EXIF `Model` is always the bare code; some video paths
    /// (the heuristic text scan, and the box-walk decoder's friendlier-name
    /// lookup) produce a "DJI <product name>" string instead. Both must
    /// normalize to the identical label.
    func testDJIBareModelCodeAndProductNameConvergeToSameLabel() {
        XCTAssertEqual(
            normalizer.normalizedModelIdentifier(forLabeling: "AC003"),
            normalizer.normalizedModelIdentifier(forLabeling: "DJI OsmoAction4")
        )
        XCTAssertEqual(normalizer.normalizedModelIdentifier(forLabeling: "AC003"), "OsmoAction4")

        XCTAssertEqual(
            normalizer.normalizedModelIdentifier(forLabeling: "FC8482"),
            normalizer.normalizedModelIdentifier(forLabeling: "DJI Mini4 Pro")
        )
        XCTAssertEqual(normalizer.normalizedModelIdentifier(forLabeling: "FC8482"), "Mini4 Pro")

        XCTAssertEqual(normalizer.normalizedModelIdentifier(forLabeling: "PP-101"), "OsmoPocket3")
    }

    func testSamsungModelNumberMapsToMarketingName() {
        XCTAssertEqual(
            normalizer.normalizedModelIdentifier(forLabeling: "SM-A546B"),
            "Galaxy A54 5G"
        )
        XCTAssertEqual(
            normalizer.normalizedModelIdentifier(forLabeling: "sm-a546b"),
            "Galaxy A54 5G"
        )
    }

    func testUnknownModelCodeIsUnaffectedByMapping() {
        XCTAssertEqual(
            normalizer.normalizedModelIdentifier(forLabeling: "SM-S911B"),
            "SM-S911B"
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
