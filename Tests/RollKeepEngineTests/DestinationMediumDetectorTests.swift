import Foundation
import RollKeepCore
import XCTest
@testable import RollKeepEngine

private struct StubDestinationMediumDetector: DestinationMediumDetecting {
    let result: DestinationMediumType

    func detectMediumType(at destinationURL: URL) -> DestinationMediumType {
        result
    }
}

final class DestinationMediumDetectorTests: XCTestCase {
    private var tempRoot: URL!

    override func setUpWithError() throws {
        let unique = "rollkeep-medium-detector-\(UUID().uuidString.lowercased())"
        tempRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(unique, isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
    }

    func testClassifyDeviceCharacteristicsHandlesMediumTypeAndRotationRate() {
        XCTAssertEqual(
            IOKitDestinationMediumDetector.classifyDeviceCharacteristics(["Medium Type": "Rotational"]),
            .rotationalHDD
        )
        XCTAssertEqual(
            IOKitDestinationMediumDetector.classifyDeviceCharacteristics(["Medium Type": "Solid State"]),
            .solidState
        )
        XCTAssertEqual(
            IOKitDestinationMediumDetector.classifyDeviceCharacteristics(["Rotation Rate": 7200]),
            .rotationalHDD
        )
        XCTAssertNil(
            IOKitDestinationMediumDetector.classifyDeviceCharacteristics(["Rotation Rate": 0])
        )
        XCTAssertNil(
            IOKitDestinationMediumDetector.classifyDeviceCharacteristics(["Medium Type": "Virtual"])
        )
        XCTAssertNil(
            IOKitDestinationMediumDetector.classifyDeviceCharacteristics([:])
        )
    }

    func testStagingCopyEngineAndIngestRequestDefaultToSingleParallelCopy() {
        XCTAssertEqual(StagingCopyEngine.Configuration().maxParallelCopies, 1)

        let request = IngestRequest(
            sourceURL: tempRoot.appendingPathComponent("source", isDirectory: true),
            destinationURL: tempRoot.appendingPathComponent("dest", isDirectory: true),
            sourceResolution: "explicit",
            destinationResolution: "explicit",
            pathScheme: ImportPathScheme(
                chronologicalLayout: .yearYearMonthCompact,
                includeCameraFolder: true,
                splitPhotoCompression: false
            ),
            dryRun: true,
            writePDF: false,
            jsonSummaryRequested: false,
            detectTimeoutSeconds: 60,
            pickSource: false,
            pickDestination: false
        )
        XCTAssertEqual(request.maxParallelCopies, 1)
    }

    func testIOKitDetectorHandlesNonExistentChildDirectorySafely() {
        let missingChild = tempRoot
            .appendingPathComponent("missing-a", isDirectory: true)
            .appendingPathComponent("missing-b", isDirectory: true)

        let detected = IOKitDestinationMediumDetector().detectMediumType(at: missingChild)
        XCTAssertTrue([.rotationalHDD, .solidState, .unknown].contains(detected))
    }

    func testSessionStartedReceiptRecordsDetectedDestinationMediumType() throws {
        let source = tempRoot.appendingPathComponent("source", isDirectory: true)
        let dcim = source.appendingPathComponent("DCIM", isDirectory: true)
        let dest = tempRoot.appendingPathComponent("dest", isDirectory: true)
        try FileManager.default.createDirectory(at: dcim, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: dcim.appendingPathComponent("IMG_0001.JPG").path,
            contents: Data("abc".utf8)
        )

        let request = IngestRequest(
            sourceURL: source,
            destinationURL: dest,
            sourceResolution: "explicit",
            destinationResolution: "explicit",
            pathScheme: ImportPathScheme(
                chronologicalLayout: .yearYearMonthCompact,
                includeCameraFolder: true,
                splitPhotoCompression: false
            ),
            dryRun: true,
            writePDF: false,
            maxParallelCopies: 1,
            jsonSummaryRequested: false,
            detectTimeoutSeconds: 60,
            pickSource: false,
            pickDestination: false
        )

        let session = IngestSession(
            request: request,
            logger: NoopIngestLogger(),
            destinationMediumDetector: StubDestinationMediumDetector(result: .rotationalHDD)
        )
        let result = try session.run()

        let receiptText = try String(contentsOfFile: result.receiptPath, encoding: .utf8)
        let firstLine = try XCTUnwrap(receiptText.split(separator: "\n").first.map(String.init))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(firstLine.utf8)) as? [String: Any])
        XCTAssertEqual(json["event_type"] as? String, "SESSION_STARTED")
        let data = try XCTUnwrap(json["data"] as? [String: Any])
        XCTAssertEqual(data["destination_medium_type"] as? String, "rotational_hdd")
        XCTAssertEqual(data["max_parallel_copies"] as? Int, 1)
    }
}
