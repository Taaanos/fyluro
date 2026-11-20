import Foundation
import XCTest
@testable import FyluroCore

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

    func testFindsFriendlierModelViaPrintableStringHeuristic() {
        let data = Data("junk\u{0}\u{0}DJI OsmoAction6\u{0}\u{0}more junk".utf8)

        let model = EmbeddedVideoMetadataTextParser().findFriendlierModel(in: data)

        XCTAssertEqual(model, "DJI OsmoAction6")
    }

    func testFindFriendlierModelReturnsNilWhenNoHeuristicMatch() {
        let data = Data("nothing interesting here".utf8)

        XCTAssertNil(EmbeddedVideoMetadataTextParser().findFriendlierModel(in: data))
    }

    func testEmbeddedParserFallsBackToPrintableGoProModelString() {
        let snapshot = EmbeddedVideoMetadataTextParser().parse(
            rawText: "",
            printableStrings: ["random", "HERO10 BlackSTRM", "CameraOrientation"],
            parser: VideoCreationDateParser()
        )

        XCTAssertEqual(snapshot.cameraModel, "HERO10 Black")
    }

    func testEmbeddedParserFallsBackToPrintableInsta360ModelString() {
        let snapshot = EmbeddedVideoMetadataTextParser().parse(
            rawText: "",
            printableStrings: ["random", "Insta360 ONE X2", "CameraOrientation"],
            parser: VideoCreationDateParser()
        )

        XCTAssertEqual(snapshot.cameraModel, "Insta360 ONE X2")
    }

    func testEmbeddedParserFallsBackToPrintableInsta360MakeString() {
        let snapshot = EmbeddedVideoMetadataTextParser().parse(
            rawText: "",
            printableStrings: ["Insta360"],
            parser: VideoCreationDateParser()
        )

        XCTAssertEqual(snapshot.cameraMake, "Insta360")
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
