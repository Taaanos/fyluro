import Foundation
import FyluroCore
import XCTest
@testable import FyluroEngine

final class DestinationMediumDetectorTests: XCTestCase {
    private var tempRoot: URL!

    override func setUpWithError() throws {
        let unique = "fyluro-medium-detector-\(UUID().uuidString.lowercased())"
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

    func testIOKitDetectorHandlesNonExistentChildDirectorySafely() {
        let missingChild = tempRoot
            .appendingPathComponent("missing-a", isDirectory: true)
            .appendingPathComponent("missing-b", isDirectory: true)

        let detected = IOKitDestinationMediumDetector().detectMediumType(at: missingChild)
        XCTAssertTrue([.rotationalHDD, .solidState, .unknown].contains(detected))
    }
}
