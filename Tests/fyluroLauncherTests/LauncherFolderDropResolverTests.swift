import Foundation
import XCTest
@testable import fyluroLauncher

final class LauncherFolderDropResolverTests: XCTestCase {
    private var tempRoot: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("fyluro-drop-resolver-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
        tempRoot = nil
        try super.tearDownWithError()
    }

    func testRejectsFileDropInsteadOfUsingParentFolder() throws {
        let folder = tempRoot.appendingPathComponent("folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("photo.jpg", isDirectory: false)
        FileManager.default.createFile(atPath: file.path, contents: Data("x".utf8))

        let resolution = LauncherFolderDropResolver.resolve([file])

        XCTAssertEqual(resolution, .rejected("Drop a folder, not a file."))
    }

    func testResolvesSymlinkToFolderAsCanonicalTarget() throws {
        let folder = tempRoot.appendingPathComponent("real", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let link = tempRoot.appendingPathComponent("link", isDirectory: false)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: folder)

        let resolution = LauncherFolderDropResolver.resolve([link])

        XCTAssertEqual(resolution, .folder(folder.path))
    }
}
