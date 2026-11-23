import Foundation
import XCTest
@testable import fyluroLauncher

@MainActor
final class LauncherDestinationFreeSpaceTests: XCTestCase {
    func testValidDestinationShowsFreeSpaceWhenSourceIsEmptyAndClearsWhenDestinationCleared() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fyluro-dest-space-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let viewModel = LauncherViewModel(workspaceNotificationCenter: NotificationCenter())
        XCTAssertTrue(viewModel.sourcePath.isEmpty)
        XCTAssertNil(viewModel.destinationFreeSpaceRowText)

        viewModel.destinationPath = tempDir.path

        let deadline = Date().addingTimeInterval(2.0)
        while viewModel.destinationFreeSpaceRowText == nil && Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        let freeSpaceText = try XCTUnwrap(viewModel.destinationFreeSpaceRowText)
        XCTAssertTrue(freeSpaceText.hasSuffix(" free"), "Expected free space suffix, got: \(freeSpaceText)")
        XCTAssertFalse(viewModel.isDestinationSpaceBlocking)
        XCTAssertNil(viewModel.destinationSpaceWarningText)

        viewModel.destinationPath = ""
        XCTAssertNil(viewModel.destinationFreeSpaceRowText)
    }
}
