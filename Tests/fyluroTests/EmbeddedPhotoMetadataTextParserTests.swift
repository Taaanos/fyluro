import XCTest
@testable import FyluroCore

final class EmbeddedPhotoMetadataTextParserTests: XCTestCase {
    private let parser = EmbeddedPhotoMetadataTextParser()

    func testParseExtractsProductNameAndSerialFromNamespacedAttributes() {
        let rawText = """
        <rdf:Description
            xmlns:drone-dji="http://www.dji.com/drone-dji/1.0/"
            drone-dji:ProductName="Mini4 Pro"
            drone-dji:CameraSerialNumber="TESTSERIAL0001" />
        """

        let snapshot = parser.parse(rawText: rawText)

        XCTAssertEqual(snapshot.productName, "Mini4 Pro")
        XCTAssertEqual(snapshot.cameraSerial, "TESTSERIAL0001")
    }

    func testParseReturnsEmptySnapshotWhenProductNameIsMissing() {
        let rawText = "<rdf:Description xmp:CreatorTool=\"Adobe Lightroom\" />"

        let snapshot = parser.parse(rawText: rawText)

        XCTAssertNil(snapshot.productName)
        XCTAssertNil(snapshot.cameraSerial)
    }

    func testExtractReadsEmbeddedMetadataFromRawFilePayload() throws {
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("fyluro-embedded-photo-parser-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let fileURL = tempDir.appendingPathComponent("sample.jpg", isDirectory: false)
        let payload = """
        random-prefix
        <rdf:Description xmlns:drone-dji="http://www.dji.com/drone-dji/1.0/" drone-dji:ProductName="Mini4 Pro" drone-dji:CameraSerialNumber="TESTSERIAL0001" />
        random-suffix
        """
        try Data(payload.utf8).write(to: fileURL)

        let snapshot = parser.extract(from: fileURL, byteCount: 1024)

        XCTAssertEqual(snapshot.productName, "Mini4 Pro")
        XCTAssertEqual(snapshot.cameraSerial, "TESTSERIAL0001")
    }
}
