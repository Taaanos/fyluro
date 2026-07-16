import XCTest
@testable import RollKeepCore

final class CameraModelCatalogLoaderTests: XCTestCase {
    func testShippedCatalogsDecodeAndMergeToExpectedEntries() {
        let merged = CameraModelCatalogLoader().loadMergedCatalog()

        XCTAssertEqual(merged["AC003"], "OsmoAction4")
        XCTAssertEqual(merged["AC006"], "OsmoAction6")
        XCTAssertEqual(merged["FC8482"], "Mini4 Pro")
        XCTAssertEqual(merged["PP-101"], "OsmoPocket3")
        XCTAssertEqual(merged["SM-A546B"], "Galaxy A54 5G")
        XCTAssertNil(merged["NOT-A-REAL-CODE"])
    }

    func testSharedCatalogMatchesFreshLoad() {
        XCTAssertEqual(CameraModelCatalog.shared, CameraModelCatalogLoader().loadMergedCatalog())
    }

    /// The safety net that matters most once this catalog grows to hundreds
    /// of entries: two vendor files silently claiming the same code would
    /// otherwise merge with undefined precedence, masking a copy/paste bug.
    func testNoDuplicateCodesAcrossVendorFiles() {
        let catalogs = CameraModelCatalogLoader().loadVendorCatalogs()
        XCTAssertFalse(catalogs.isEmpty, "expected at least the shipped DJI/Samsung catalogs to load")

        var vendorsByCode: [String: [String]] = [:]
        for catalog in catalogs {
            for code in catalog.entries.keys {
                vendorsByCode[code, default: []].append(catalog.vendor)
            }
        }

        let collisions = vendorsByCode.filter { $0.value.count > 1 }
        XCTAssertTrue(
            collisions.isEmpty,
            "duplicate model code(s) across vendor files: " +
                collisions.map { "\($0.key) in \($0.value.joined(separator: ", "))" }.joined(separator: "; ")
        )
    }

    func testCaseInsensitiveKeyNormalization() throws {
        let tempRoot = try makeTempCatalogDirectory(files: [
            "TestVendor.json": #"{"lower-code": "Lower Code Product"}"#,
        ])
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let bundle = try XCTUnwrap(Bundle(url: tempRoot))
        let merged = CameraModelCatalogLoader(bundle: bundle, subdirectory: "CameraModelCatalogs").loadMergedCatalog()

        XCTAssertEqual(merged["LOWER-CODE"], "Lower Code Product")
    }

    func testMalformedFileContributesNothingAndDoesNotCrash() throws {
        let tempRoot = try makeTempCatalogDirectory(files: [
            "Valid.json": #"{"OK001": "Known Good"}"#,
            "Malformed.json": "{ this is not valid json",
        ])
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let bundle = try XCTUnwrap(Bundle(url: tempRoot))
        let merged = CameraModelCatalogLoader(bundle: bundle, subdirectory: "CameraModelCatalogs").loadMergedCatalog()

        XCTAssertEqual(merged["OK001"], "Known Good")
        XCTAssertEqual(merged.count, 1)
    }

    func testMissingCatalogDirectoryContributesNothingAndDoesNotCrash() throws {
        let tempRoot = try FileManager.default.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: FileManager.default.temporaryDirectory,
            create: true
        )
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let bundle = try XCTUnwrap(Bundle(url: tempRoot))
        let merged = CameraModelCatalogLoader(bundle: bundle, subdirectory: "CameraModelCatalogs").loadMergedCatalog()

        XCTAssertTrue(merged.isEmpty)
    }

    private func makeTempCatalogDirectory(files: [String: String]) throws -> URL {
        let root = try FileManager.default.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: FileManager.default.temporaryDirectory,
            create: true
        )
        let catalogsDir = root.appendingPathComponent("CameraModelCatalogs", isDirectory: true)
        try FileManager.default.createDirectory(at: catalogsDir, withIntermediateDirectories: true)

        for (name, contents) in files {
            try contents.write(to: catalogsDir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }

        return root
    }
}
