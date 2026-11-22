import Foundation
import XCTest
@testable import fyluroLauncher

final class LauncherFinderDirectoryResolverTests: XCTestCase {
    private let destination = "/Volumes/Library"

    func testEmptyDirectoriesReturnsNoActions() {
        let actions = LauncherFinderDirectoryResolver.resolveActions(
            for: [],
            destinationPath: destination
        )
        XCTAssertTrue(actions.isEmpty)
    }

    func testUpToThreeLeafDirectoriesOpenDirectly() {
        let leaves = [
            "/Volumes/Library/2026/202605/CameraA/Photos",
            "/Volumes/Library/2026/202605/CameraA/Videos",
            "/Volumes/Library/2026/202605/CameraB/Photos",
        ]

        let actions = LauncherFinderDirectoryResolver.resolveActions(
            for: leaves,
            destinationPath: destination
        )

        XCTAssertEqual(actions, leaves.map { .openDirectory(URL(fileURLWithPath: $0, isDirectory: true)) })
    }

    func testMoreThanThreeLeavesInSingleParentStepsUpOnceAndHighlightsLeaves() {
        let leaves = [
            "/Volumes/Library/2026/202605/20260501",
            "/Volumes/Library/2026/202605/20260502",
            "/Volumes/Library/2026/202605/20260503",
            "/Volumes/Library/2026/202605/20260504",
        ]

        let actions = LauncherFinderDirectoryResolver.resolveActions(
            for: leaves,
            destinationPath: destination
        )

        XCTAssertEqual(actions, [
            .revealInParent(leaves.map { URL(fileURLWithPath: $0, isDirectory: true) }),
        ])
    }

    func testMoreThanThreeLeavesAcrossTwoParentsOpensTwoParentWindows() {
        let aprilLeaves = [
            "/Volumes/Library/2026/202604/20260429",
            "/Volumes/Library/2026/202604/20260430",
        ]
        let mayLeaves = [
            "/Volumes/Library/2026/202605/20260501",
            "/Volumes/Library/2026/202605/20260502",
        ]

        let actions = LauncherFinderDirectoryResolver.resolveActions(
            for: aprilLeaves + mayLeaves,
            destinationPath: destination
        )

        XCTAssertEqual(actions, [
            .revealInParent(aprilLeaves.map { URL(fileURLWithPath: $0, isDirectory: true) }),
            .revealInParent(mayLeaves.map { URL(fileURLWithPath: $0, isDirectory: true) }),
        ])
    }

    func testMoreThanThreeParentsStepsUpToGrandparentAndHighlightsParents() {
        let leaves = [
            "/Volumes/Library/2026/202601/Photos",
            "/Volumes/Library/2026/202602/Photos",
            "/Volumes/Library/2026/202603/Photos",
            "/Volumes/Library/2026/202604/Photos",
            "/Volumes/Library/2026/202605/Photos",
        ]

        let actions = LauncherFinderDirectoryResolver.resolveActions(
            for: leaves,
            destinationPath: destination
        )

        let expectedMonths = [
            "/Volumes/Library/2026/202601",
            "/Volumes/Library/2026/202602",
            "/Volumes/Library/2026/202603",
            "/Volumes/Library/2026/202604",
            "/Volumes/Library/2026/202605",
        ].map { URL(fileURLWithPath: $0, isDirectory: true) }

        XCTAssertEqual(actions, [.revealInParent(expectedMonths)])
    }

    func testNeverTraversesAboveDestinationPath() {
        let leaves = [
            "/Volumes/Library/2022/Photos",
            "/Volumes/Library/2023/Photos",
            "/Volumes/Library/2024/Photos",
            "/Volumes/Library/2025/Photos",
            "/Volumes/Library/2026/Photos",
        ]

        let actions = LauncherFinderDirectoryResolver.resolveActions(
            for: leaves,
            destinationPath: destination
        )

        let expectedYears = [
            "/Volumes/Library/2022",
            "/Volumes/Library/2023",
            "/Volumes/Library/2024",
            "/Volumes/Library/2025",
            "/Volumes/Library/2026",
        ].map { URL(fileURLWithPath: $0, isDirectory: true) }

        XCTAssertEqual(actions, [.revealInParent(expectedYears)])
    }

    func testMixedDepthPrunesRedundantDescendantAndHighlightsTopLevelChildren() {
        let leaves = [
            "/Volumes/Library/2026/202605/01",
            "/Volumes/Library/2026/202605/02",
            "/Volumes/Library/2026/202605/03",
            "/Volumes/Library/UnknownDate",
        ]

        let actions = LauncherFinderDirectoryResolver.resolveActions(
            for: leaves,
            destinationPath: destination
        )

        let expectedChildren = [
            "/Volumes/Library/2026",
            "/Volumes/Library/UnknownDate",
        ].map { URL(fileURLWithPath: $0, isDirectory: true) }

        XCTAssertEqual(actions, [.revealInParent(expectedChildren)])
    }
}
