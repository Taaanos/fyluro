import XCTest
@testable import RollKeepCore

final class ImportPathSchemeTests: XCTestCase {
    func testPhotoCompressionClassifierUsesRawAllowlist() {
        let classifier = PhotoCompressionClassifier()

        for ext in PhotoCompressionClassifier.rawExtensions {
            XCTAssertEqual(classifier.bucket(forRelativePath: "DCIM/PHOTO.\(ext.uppercased())"), .raw)
        }

        XCTAssertEqual(classifier.bucket(forRelativePath: "DCIM/PHOTO.JPG"), .nonRaw)
        XCTAssertEqual(classifier.bucket(forRelativePath: "DCIM/PHOTO.HEIC"), .nonRaw)
    }

    func testReceiptPathSchemeStringOmitsDisabledSegments() {
        let scheme = ImportPathScheme(
            chronologicalLayout: .yearMonthNested,
            includeCameraFolder: false,
            splitPhotoCompression: false
        )

        XCTAssertEqual(
            scheme.receiptPathSchemeString,
            "YYYY/MM/<Photos|Videos>/<filename> ; _unsorted/<Photos|Videos>/<filename>"
        )
    }

    func testReceiptPathSchemeStringIncludesCameraAndCompressionWhenEnabled() {
        let scheme = ImportPathScheme(
            chronologicalLayout: .yearYearMonthCompact,
            includeCameraFolder: true,
            splitPhotoCompression: true
        )

        XCTAssertEqual(
            scheme.receiptPathSchemeString,
            "YYYY/YYYYMM/<Camera>/<Photos|Videos>/<RAW|Non-RAW (Photos)>/<filename> ; _unsorted/<Camera>/<Photos|Videos>/<RAW|Non-RAW (Photos)>/<filename>"
        )
    }

    func testReceiptPathSchemeStringSupportsYearOnlyLayout() {
        let scheme = ImportPathScheme(
            chronologicalLayout: .yearOnly,
            includeCameraFolder: true,
            splitPhotoCompression: false
        )

        XCTAssertEqual(
            scheme.receiptPathSchemeString,
            "YYYY/<Camera>/<Photos|Videos>/<filename> ; _unsorted/<Camera>/<Photos|Videos>/<filename>"
        )
    }

    func testChronologicalLayoutParseCLIValueAcceptsSupportedValues() {
        XCTAssertEqual(PathChronologicalLayout.parseCLIValue("YYYY/YYYYMM"), .yearYearMonthCompact)
        XCTAssertEqual(PathChronologicalLayout.parseCLIValue("YYYY/MM"), .yearMonthNested)
        XCTAssertEqual(PathChronologicalLayout.parseCLIValue("YYYY"), .yearOnly)
        XCTAssertNil(PathChronologicalLayout.parseCLIValue("YYYY-DD"))
    }
}
