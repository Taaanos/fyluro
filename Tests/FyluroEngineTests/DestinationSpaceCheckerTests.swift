import Foundation
import XCTest
@testable import FyluroEngine

final class DestinationSpaceCheckerTests: XCTestCase {
    private var tempRoot: URL!

    override func setUpWithError() throws {
        let unique = "fyluro-space-checker-tests-\(UUID().uuidString.lowercased())"
        tempRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(unique, isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
    }

    func testSufficientSpaceForSmallCopy() {
        let outcome = DestinationSpaceChecker.check(destinationURL: tempRoot, bytesToCopy: 4096)
        guard case .sufficient = outcome else {
            return XCTFail("Expected .sufficient, got a different outcome")
        }
    }

    func testInsufficientSpaceForHugeCopy() {
        let hugeByteCount = Int64.max / 2
        let outcome = DestinationSpaceChecker.check(destinationURL: tempRoot, bytesToCopy: hugeByteCount)
        guard case .insufficient(let details) = outcome else {
            return XCTFail("Expected .insufficient, got a different outcome")
        }
        let expectedHeadroom = Int64((Double(hugeByteCount) * DestinationSpaceChecker.headroomFraction).rounded(.up))
        XCTAssertEqual(details.requiredBytes, hugeByteCount + expectedHeadroom)
        XCTAssertLessThan(details.availableBytes, details.requiredBytes)

        let message = DestinationSpaceChecker.message(for: details, bytesToCopy: hugeByteCount)
        XCTAssertTrue(message.contains("insufficient free space"))
    }

    func testUnableToDetermineForNonexistentDestination() {
        let missing = tempRoot.appendingPathComponent("does-not-exist-\(UUID().uuidString)", isDirectory: true)
        let outcome = DestinationSpaceChecker.check(destinationURL: missing, bytesToCopy: 4096)
        guard case .unableToDetermine = outcome else {
            return XCTFail("Expected .unableToDetermine, got a different outcome")
        }
    }
}
