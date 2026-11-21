import Foundation
import XCTest
@testable import FyluroCore

final class EmbeddedVideoMetadataTextParserTests: XCTestCase {
    func testEmbeddedParserReadsSonyXmlDeviceMetadata() {
        let rawText = """
        <NonRealTimeMeta lastUpdate="2024-06-21T22:05:59+01:00">
        <CreationDate value="2024-06-21T22:05:01+01:00"/>
        <Device manufacturer="Sony" modelName="ILCE-7CM2" serialNo="4294967295"/>
        </NonRealTimeMeta>
        """

        let snapshot = EmbeddedVideoMetadataTextParser().parse(
            rawText: rawText,
            printableStrings: [],
            parser: VideoCreationDateParser()
        )

        XCTAssertEqual(snapshot.cameraMake, "Sony")
        XCTAssertEqual(snapshot.cameraModel, "ILCE-7CM2")
        XCTAssertNil(snapshot.cameraSerial)
        XCTAssertNotNil(snapshot.captureDateTime)
    }

    func testEmbeddedParserPrefersXmlDeviceModelOverHeuristicPrintableMatch() {
        let snapshot = EmbeddedVideoMetadataTextParser().parse(
            rawText: "",
            printableStrings: [
                "BXR-Z0",
                #"<CreationDate value="2024-06-21T22:05:01+01:00"/>"#,
                #"<Device manufacturer="Sony" modelName="ILCE-7CM2" serialNo="4294967295"/>"#,
            ],
            parser: VideoCreationDateParser()
        )

        XCTAssertEqual(snapshot.cameraMake, "Sony")
        XCTAssertEqual(snapshot.cameraModel, "ILCE-7CM2")
        XCTAssertNil(snapshot.cameraSerial)
        XCTAssertNotNil(snapshot.captureDateTime)
    }

    /// Regression test for RT-P1-10: the labeled-field regexes (e.g.
    /// `Model\s*[:=]\s*([^\r\n<]+)`) have no max-length bound on their own,
    /// so a crafted field used to survive sanitization as a single unbroken
    /// token of unbounded length, flowing into the camera label, path
    /// components, and PDF rendering. `sanitize()` now rejects (rather than
    /// truncates) any value over 128 UTF-8 bytes -- comfortably above any
    /// real make/model/serial string (e.g. "Apple iPhone 15 Pro 13mm" is
    /// ~24 chars) -- so a value this implausible is treated like any other
    /// unresolvable field rather than propagated.
    func testEmbeddedParserRejectsOversizedLabeledModelField() {
        let hostileModel = String(repeating: "A", count: 2_000_000)
        let rawText = "Model: \(hostileModel)"

        let snapshot = EmbeddedVideoMetadataTextParser().parse(
            rawText: rawText,
            printableStrings: [],
            parser: VideoCreationDateParser()
        )

        XCTAssertNil(snapshot.cameraModel)
    }

    func testEmbeddedParserAcceptsModelFieldAtLengthCapBoundary() {
        let boundaryModel = String(repeating: "A", count: 128)
        let rawText = "Model: \(boundaryModel)"

        let snapshot = EmbeddedVideoMetadataTextParser().parse(
            rawText: rawText,
            printableStrings: [],
            parser: VideoCreationDateParser()
        )

        XCTAssertEqual(snapshot.cameraModel, boundaryModel)
    }

    func testEmbeddedParserPrefersRealDJIModelOverEarlierDebugMarkers() {
        // Reproduces the DJI Mini 4 Pro's embedded metadata block, where firmware
        // debug/section markers ("DJI meta", "DJI dbgi") precede the real model
        // string ("DJI Mini4 Pro") in file order but must not be picked instead.
        let snapshot = EmbeddedVideoMetadataTextParser().parse(
            rawText: "",
            printableStrings: ["DJI meta", "DJI dbgi", "DJI Mini4 Pro"],
            parser: VideoCreationDateParser()
        )

        XCTAssertEqual(snapshot.cameraModel, "DJI Mini4 Pro")
    }

    func testEmbeddedParserIgnoresOpaqueDJISensorCodeWithoutLowercase() {
        let snapshot = EmbeddedVideoMetadataTextParser().parse(
            rawText: "",
            printableStrings: ["DJI AC006-", "DJI FC8482-"],
            parser: VideoCreationDateParser()
        )

        XCTAssertNil(snapshot.cameraModel)
    }
}
