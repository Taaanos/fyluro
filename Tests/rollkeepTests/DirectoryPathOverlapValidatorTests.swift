import Foundation
import XCTest
@testable import RollKeepCore

final class DirectoryPathOverlapValidatorTests: XCTestCase {
    private var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("rollkeep-path-overlap-\(UUID().uuidString.lowercased())", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
    }

    func testAnalyzeTreatsSamePathAsSame() throws {
        let source = try createDirectory(named: "card")

        let analysis = DirectoryPathOverlapValidator.analyze(
            sourcePath: source.path,
            destinationPath: source.path
        )

        XCTAssertEqual(analysis.relation, .same)
        XCTAssertEqual(analysis.sourcePath, source.path)
        XCTAssertEqual(analysis.destinationPath, source.path)
    }

    func testAnalyzeTreatsNestedDestinationAsSourceContainsDestination() throws {
        let source = try createDirectory(named: "card")
        let destination = source.appendingPathComponent("library", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        let analysis = DirectoryPathOverlapValidator.analyze(
            sourcePath: source.path,
            destinationPath: destination.path
        )

        XCTAssertEqual(analysis.relation, .sourceContainsDestination)
    }

    func testAnalyzeTreatsNestedSourceAsDestinationContainsSource() throws {
        let destination = try createDirectory(named: "library")
        let source = destination.appendingPathComponent("card", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)

        let analysis = DirectoryPathOverlapValidator.analyze(
            sourcePath: source.path,
            destinationPath: destination.path
        )

        XCTAssertEqual(analysis.relation, .destinationContainsSource)
    }

    func testAnalyzeKeepsPrefixSharingSiblingsDisjoint() throws {
        let source = try createDirectory(named: "card")
        let destination = try createDirectory(named: "card-backup")

        let analysis = DirectoryPathOverlapValidator.analyze(
            sourcePath: source.path,
            destinationPath: destination.path
        )

        XCTAssertEqual(analysis.relation, .disjoint)
    }

    func testAnalyzeKeepsSameDriveSiblingDirectoriesDisjoint() throws {
        let source = try createDirectory(named: "source-a")
        let destination = try createDirectory(named: "source-b")

        let analysis = DirectoryPathOverlapValidator.analyze(
            sourcePath: source.path,
            destinationPath: destination.path
        )

        XCTAssertEqual(analysis.relation, .disjoint)
    }

    func testAnalyzeResolvesSymlinkAliasToSamePath() throws {
        let source = try createDirectory(named: "card")
        let symlink = tempRoot.appendingPathComponent("card-alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(atPath: symlink.path, withDestinationPath: source.path)

        let analysis = DirectoryPathOverlapValidator.analyze(
            sourcePath: source.path,
            destinationPath: symlink.path
        )

        XCTAssertEqual(analysis.relation, .same)
        XCTAssertEqual(analysis.destinationPath, source.path)
    }

    private func createDirectory(named name: String) throws -> URL {
        let url = tempRoot.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
