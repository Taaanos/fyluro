import XCTest
@testable import RollKeepCore

final class CameraUserCatalogReaderTests: XCTestCase {
    private var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = try FileManager.default.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: FileManager.default.temporaryDirectory,
            create: true
        )
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    func testMissingFileIsMissingAndContributesNothing() {
        let reader = CameraUserCatalogReader(fileURL: tempRoot.appendingPathComponent("CameraCatalog.json"))

        XCTAssertEqual(reader.load(), .missing)
        XCTAssertTrue(reader.loadEntries().isEmpty)
    }

    func testValidFileLoadsNormalizedKeysAndTrimmedNames() throws {
        let url = try write(#"{"sm-a546b": "  Galaxy A54 5G ", " ac003 ": "OsmoAction4"}"#)

        XCTAssertEqual(
            CameraUserCatalogReader(fileURL: url).load(),
            .loaded(["SM-A546B": "Galaxy A54 5G", "AC003": "OsmoAction4"])
        )
    }

    func testBlankCodesAndBlankNamesAreSkipped() throws {
        let url = try write(#"{"  ": "No Code", "OK001": "   ", "OK002": "Good"}"#)

        XCTAssertEqual(CameraUserCatalogReader(fileURL: url).loadEntries(), ["OK002": "Good"])
    }

    func testMalformedFileIsReportedAndContributesNothing() throws {
        let url = try write("{ this is not valid json")
        let result = CameraUserCatalogReader(fileURL: url).load()

        guard case .malformed = result else {
            return XCTFail("expected .malformed, got \(result)")
        }
        XCTAssertTrue(result.entries.isEmpty)
    }

    func testWrongValueTypeIsMalformed() throws {
        let url = try write(#"{"AC003": 4}"#)

        guard case .malformed = CameraUserCatalogReader(fileURL: url).load() else {
            return XCTFail("expected .malformed")
        }
    }

    func testEnvironmentOverrideSelectsFileLocation() {
        let overridden = CameraUserCatalogFileLocation.fileURL(
            environment: [CameraUserCatalogFileLocation.environmentOverrideKey: "/tmp/custom-catalog.json"]
        )
        XCTAssertEqual(overridden.path, "/tmp/custom-catalog.json")

        let defaulted = CameraUserCatalogFileLocation.fileURL(environment: [:])
        XCTAssertTrue(defaulted.path.hasSuffix("Application Support/RollKeep/CameraCatalog.json"))
    }

    func testMapRuleUsesCatalogKeysCaseInsensitivelyAndFallsBackToRawCode() {
        let rule = MapKnownModelCodeToProductNameRule(modelCodeMap: ["SM-A546B": "Galaxy A54 5G"])

        XCTAssertEqual(rule.apply(to: "sm-a546b"), "Galaxy A54 5G")
        XCTAssertEqual(rule.apply(to: " SM-A546B "), "Galaxy A54 5G")
        XCTAssertEqual(rule.apply(to: "SM-S911B"), "SM-S911B")
    }

    func testFolderLabelPreviewMatchesRealLabelingRules() {
        XCTAssertEqual(CameraLabeler.folderLabel(forCatalogName: "Galaxy A54 5G"), "galaxy-a54-5g")
        XCTAssertEqual(CameraLabeler.folderLabel(forCatalogName: "Sony α7 IV"), "sony-7-iv")
        XCTAssertEqual(CameraLabeler.folderLabel(forCatalogName: "DJI Osmo Action 4"), "osmo-action-4")
        XCTAssertNil(CameraLabeler.folderLabel(forCatalogName: "日本カメラ"))
        XCTAssertNil(CameraLabeler.folderLabel(forCatalogName: "   "))
    }

    private func write(_ contents: String) throws -> URL {
        let url = tempRoot.appendingPathComponent("CameraCatalog.json")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
