import Foundation
import XCTest
@testable import FyluroCore
@testable import fyluroLauncher

@MainActor
final class LauncherAppE2ETests: XCTestCase {
    nonisolated override class func setUp() {
        super.setUp()
        setenv(
            CameraUserCatalogFileLocation.environmentOverrideKey,
            NSTemporaryDirectory() + "fyluro-no-catalog-\(UUID().uuidString).json",
            1
        )
    }

    struct FixtureSource {
        let label: String
        let relativePath: String
        let matrixSlimRelativePaths: [String]

        static let all: [FixtureSource] = [
            FixtureSource(
                label: "SD_CARD1",
                relativePath: "Tests/TestingDirs/SD_CARD1",
                matrixSlimRelativePaths: [
                    "DCIM/IMG_8236.HEIC",
                    "DCIM/IMG_0187.HEIC",
                ]
            ),
            FixtureSource(
                label: "SD_CARD2",
                relativePath: "Tests/TestingDirs/SD_CARD2",
                matrixSlimRelativePaths: [
                    "DCIM/100MSDCF/DSC01930.JPG",
                    "PRIVATE/M4ROOT/CLIP/20250824_C2864.MP4",
                ]
            ),
        ]
    }

    struct PathSchemeCase {
        let id: String
        let configuration: LauncherPathSchemeConfiguration

        static let all: [PathSchemeCase] = [
            PathSchemeCase(
                id: "E2E-025",
                configuration: LauncherPathSchemeConfiguration(
                    chronologicalLayout: .yearYearMonthCompact,
                    includeCameraFolder: true,
                    splitPhotoCompression: false
                )
            ),
            PathSchemeCase(
                id: "E2E-026",
                configuration: LauncherPathSchemeConfiguration(
                    chronologicalLayout: .yearMonthNested,
                    includeCameraFolder: true,
                    splitPhotoCompression: false
                )
            ),
            PathSchemeCase(
                id: "E2E-027",
                configuration: LauncherPathSchemeConfiguration(
                    chronologicalLayout: .yearYearMonthCompact,
                    includeCameraFolder: false,
                    splitPhotoCompression: false
                )
            ),
            PathSchemeCase(
                id: "E2E-028",
                configuration: LauncherPathSchemeConfiguration(
                    chronologicalLayout: .yearYearMonthCompact,
                    includeCameraFolder: true,
                    splitPhotoCompression: true
                )
            ),
            PathSchemeCase(
                id: "E2E-029",
                configuration: LauncherPathSchemeConfiguration(
                    chronologicalLayout: .yearMonthNested,
                    includeCameraFolder: false,
                    splitPhotoCompression: false
                )
            ),
            PathSchemeCase(
                id: "E2E-030",
                configuration: LauncherPathSchemeConfiguration(
                    chronologicalLayout: .yearMonthNested,
                    includeCameraFolder: true,
                    splitPhotoCompression: true
                )
            ),
            PathSchemeCase(
                id: "E2E-031",
                configuration: LauncherPathSchemeConfiguration(
                    chronologicalLayout: .yearYearMonthCompact,
                    includeCameraFolder: false,
                    splitPhotoCompression: true
                )
            ),
            PathSchemeCase(
                id: "E2E-032",
                configuration: LauncherPathSchemeConfiguration(
                    chronologicalLayout: .yearMonthNested,
                    includeCameraFolder: false,
                    splitPhotoCompression: true
                )
            ),
            PathSchemeCase(
                id: "year-only",
                configuration: LauncherPathSchemeConfiguration(
                    chronologicalLayout: .yearOnly,
                    includeCameraFolder: true,
                    splitPhotoCompression: false
                )
            ),
        ]
    }

    struct RunArtifacts {
        let viewModel: LauncherViewModel
        let finder: StubLauncherFinderOpening
        let receiptPath: String
        let receiptEvents: [[String: Any]]
        let summaryData: [String: Any]
        let destination: URL
        let source: URL
    }

    struct FileSnapshot: Equatable {
        let sha256: String
        let size: UInt64
        let mtimeNanoseconds: UInt64
    }

    var repoRoot: URL!

    override func setUpWithError() throws {
        if ProcessInfo.processInfo.environment["FYLURO_RUN_APP_E2E"] != "1" {
            throw XCTSkip("Set FYLURO_RUN_APP_E2E=1 to run launcher app E2E tests.")
        }

        repoRoot = try resolveRepoRoot()
    }
}
