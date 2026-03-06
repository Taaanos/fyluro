import Foundation
import XCTest
@testable import rollkeep

final class SourceScannerTests: XCTestCase {
    private var tempRoot: URL!

    override func setUpWithError() throws {
        let unique = "rollkeep-tests-\(UUID().uuidString.lowercased())"
        tempRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(unique, isDirectory: true)

        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
    }

    func testScanExcludesHiddenAndSystemEntriesAndCountsMedia() throws {
        try createFile(path: "DCIM/100MEDIA/IMG_0001.JPG", bytes: 10)
        try createFile(path: "DCIM/100MEDIA/clip001.MOV", bytes: 20)
        try createFile(path: ".Trashes/hidden.jpg", bytes: 30)
        try createFile(path: "System Volume Information/sys.mp4", bytes: 40)
        try createFile(path: "docs/readme.txt", bytes: 50)

        let summary = try SourceScanner().scan(sourceRoot: tempRoot)

        XCTAssertEqual(summary.photoCount, 1)
        XCTAssertEqual(summary.videoCount, 1)
        XCTAssertEqual(summary.photoBytes, 10)
        XCTAssertEqual(summary.videoBytes, 20)
        XCTAssertEqual(summary.candidates.count, 2)

        let orderedRelativePaths = summary.candidates.map(\.relativePath)
        XCTAssertEqual(orderedRelativePaths, ["DCIM/100MEDIA/clip001.MOV", "DCIM/100MEDIA/IMG_0001.JPG"])
    }

    func testScanProducesDeterministicOrder() throws {
        try createFile(path: "DCIM/B/IMG_10.JPG", bytes: 1)
        try createFile(path: "DCIM/A/IMG_2.JPG", bytes: 1)
        try createFile(path: "DCIM/A/IMG_1.JPG", bytes: 1)

        let summary = try SourceScanner().scan(sourceRoot: tempRoot)

        XCTAssertEqual(summary.candidates.map(\.relativePath), [
            "DCIM/A/IMG_1.JPG",
            "DCIM/A/IMG_2.JPG",
            "DCIM/B/IMG_10.JPG",
        ])
    }

    func testScanCollectsMtimeAndSize() throws {
        let fileURL = try createFile(path: "PRIVATE/clip.MP4", bytes: 123)

        let explicitMtime = Date(timeIntervalSince1970: 1_704_067_200)
        try FileManager.default.setAttributes([.modificationDate: explicitMtime], ofItemAtPath: fileURL.path)

        let summary = try SourceScanner().scan(sourceRoot: tempRoot)
        let item = try XCTUnwrap(summary.candidates.first)

        XCTAssertEqual(item.relativePath, "PRIVATE/clip.MP4")
        XCTAssertEqual(item.mediaType, .video)
        XCTAssertEqual(item.sizeBytes, 123)
        XCTAssertEqual(item.mtime.timeIntervalSince1970, explicitMtime.timeIntervalSince1970, accuracy: 1)
    }

    func testUnreadableSourceRootFails() throws {
        let fileURL = try createFile(path: "not-a-directory", bytes: 1)

        XCTAssertThrowsError(try SourceScanner().scan(sourceRoot: fileURL)) { error in
            guard case SourceScannerError.unreadableSourceRoot = error else {
                XCTFail("Unexpected error: \(error)")
                return
            }
        }
    }

    @discardableResult
    private func createFile(path: String, bytes: Int) throws -> URL {
        let fileURL = tempRoot.appendingPathComponent(path, isDirectory: false)
        let dirURL = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)

        let data = Data(repeating: 0x41, count: bytes)
        FileManager.default.createFile(atPath: fileURL.path, contents: data)
        return fileURL
    }
}
