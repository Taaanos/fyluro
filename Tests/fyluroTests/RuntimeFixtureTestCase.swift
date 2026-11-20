import Foundation
import XCTest

class RuntimeFixtureTestCase: XCTestCase {
    var tempRoot: URL!

    override func setUpWithError() throws {
        let unique = "fyluro-runtime-fixtures-\(UUID().uuidString.lowercased())"
        tempRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(unique, isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
    }

    @discardableResult
    func createBinaryFile(path: String, bytes: Int, fill: UInt8 = 0x41) throws -> URL {
        let fileURL = tempRoot.appendingPathComponent(path, isDirectory: false)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = Data(repeating: fill, count: bytes)
        FileManager.default.createFile(atPath: fileURL.path, contents: data)
        return fileURL
    }

    @discardableResult
    func createTextFile(path: String, contents: String) throws -> URL {
        let fileURL = tempRoot.appendingPathComponent(path, isDirectory: false)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: fileURL, atomically: true, encoding: .utf8)
        return fileURL
    }

    func setModificationDate(_ date: Date, for fileURL: URL) throws {
        try FileManager.default.setAttributes(
            [.modificationDate: date],
            ofItemAtPath: fileURL.path
        )
    }

    func fixtureURL(_ relativePath: String) -> URL {
        Self.repoRootURL
            .appendingPathComponent("Tests", isDirectory: true)
            .appendingPathComponent(relativePath, isDirectory: true)
    }

    private static var repoRootURL: URL {
        URL(fileURLWithPath: #filePath, isDirectory: false)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
