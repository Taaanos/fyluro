import Foundation
import XCTest
@testable import RollKeepCore

final class EmbeddedVideoMetadataTextParserTests: XCTestCase {
    func testVideoCreationDateParserSupportsColonSeparatedFormats() {
        let parser = VideoCreationDateParser()

        XCTAssertNotNil(parser.parse("2024:06:21 22:05:01+01:00"))
        XCTAssertNotNil(parser.parse("2024:03:14 13:34:47"))
    }

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

    func testEmbeddedParserFallsBackToLabeledModelNames() {
        let rawText = """
        Device Manufacturer               : Sony
        Device Model Name                 : ILCE-7CM2
        CreationDateValue                 : 2024:06:21 22:05:01+01:00
        """

        let snapshot = EmbeddedVideoMetadataTextParser().parse(
            rawText: rawText,
            printableStrings: [],
            parser: VideoCreationDateParser()
        )

        XCTAssertEqual(snapshot.cameraMake, "Sony")
        XCTAssertEqual(snapshot.cameraModel, "ILCE-7CM2")
        XCTAssertNotNil(snapshot.captureDateTime)
    }

    func testEmbeddedParserFallsBackToPrintableGoProModelString() {
        let snapshot = EmbeddedVideoMetadataTextParser().parse(
            rawText: "",
            printableStrings: ["random", "HERO10 BlackSTRM", "CameraOrientation"],
            parser: VideoCreationDateParser()
        )

        XCTAssertEqual(snapshot.cameraModel, "HERO10 Black")
    }

    func testEmbeddedParserFallsBackToPrintableDJIModelString() {
        let snapshot = EmbeddedVideoMetadataTextParser().parse(
            rawText: "",
            printableStrings: ["dvtm_Mini4_Pro.proto", "DJI Mini4 Pro", "DJI FC8482-"],
            parser: VideoCreationDateParser()
        )

        XCTAssertEqual(snapshot.cameraModel, "DJI Mini4 Pro")
    }

    func testEmbeddedParserFallsBackToPrintableDJIOsmoActionModelString() {
        let snapshot = EmbeddedVideoMetadataTextParser().parse(
            rawText: "",
            printableStrings: ["dvtm_ac206.proto", "DJI OsmoAction6", "DJI AC006-"],
            parser: VideoCreationDateParser()
        )

        XCTAssertEqual(snapshot.cameraModel, "DJI OsmoAction6")
    }

    func testEmbeddedParserFallsBackToPrintableDJIOsmoPocketModelString() {
        let snapshot = EmbeddedVideoMetadataTextParser().parse(
            rawText: "",
            printableStrings: ["DJI OsmoPocket3", "DJI dbgi"],
            parser: VideoCreationDateParser()
        )

        XCTAssertEqual(snapshot.cameraModel, "DJI OsmoPocket3")
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

    func testPrintableStringExtractionFindsAsciiRuns() {
        let bytes: [UInt8] = [0x00, 0x48, 0x45, 0x52, 0x4F, 0x31, 0x30, 0x20, 0x42, 0x6C, 0x61, 0x63, 0x6B, 0x00]
        let strings = EmbeddedVideoMetadataTextParser().extractPrintableStrings(from: Data(bytes), minimumLength: 6)

        XCTAssertEqual(strings, ["HERO10 Black"])
    }
}
