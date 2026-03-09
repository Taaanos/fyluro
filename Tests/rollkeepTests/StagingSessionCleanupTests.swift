import Foundation
import XCTest
@testable import rollkeep

final class StagingSessionCleanupTests: XCTestCase {
    private var tempRoot: URL!

    override func setUpWithError() throws {
        let unique = "rollkeep-staging-cleanup-tests-\(UUID().uuidString.lowercased())"
        tempRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(unique, isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
    }

    func testRemoveIfPresentDeletesExistingSessionDirectory() throws {
        let stagingRoot = tempRoot
            .appendingPathComponent("_ingest_staging", isDirectory: true)
        let stagingPath = stagingRoot
            .appendingPathComponent("session-1", isDirectory: true)
        try FileManager.default.createDirectory(at: stagingPath, withIntermediateDirectories: true)
        try Data("bytes".utf8).write(to: stagingPath.appendingPathComponent("file.txt", isDirectory: false))

        let removed = try StagingSessionCleanup().removeIfPresent(path: stagingPath.path)

        XCTAssertTrue(removed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagingPath.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagingRoot.path))
    }

    func testRemoveIfPresentReturnsFalseWhenSessionDirectoryDoesNotExist() throws {
        let missingPath = tempRoot
            .appendingPathComponent("_ingest_staging", isDirectory: true)
            .appendingPathComponent("missing-session", isDirectory: true)
            .path

        let removed = try StagingSessionCleanup().removeIfPresent(path: missingPath)

        XCTAssertFalse(removed)
    }

    func testRemoveIfPresentKeepsStagingRootWhenOtherSessionsExist() throws {
        let stagingRoot = tempRoot
            .appendingPathComponent("_ingest_staging", isDirectory: true)
        let sessionOne = stagingRoot.appendingPathComponent("session-1", isDirectory: true)
        let sessionTwo = stagingRoot.appendingPathComponent("session-2", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionOne, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sessionTwo, withIntermediateDirectories: true)

        let removed = try StagingSessionCleanup().removeIfPresent(path: sessionOne.path)

        XCTAssertTrue(removed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sessionOne.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sessionTwo.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: stagingRoot.path))
    }
}
