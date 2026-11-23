import Foundation
import XCTest
@testable import FyluroCore
@testable import fyluroLauncher

extension LauncherAppE2ETests {
    func testAppE2EPathSchemeMatrixAcrossSourcesWithSettingsAndPostRunActions() throws {
        let tempRoot = try makeTempDirectory(prefix: "fyluro-launcher-app-e2e-schemes-")
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        for fixture in FixtureSource.all {
            let fixtureSource = repoRoot.appendingPathComponent(fixture.relativePath, isDirectory: true)
            XCTAssertTrue(FileManager.default.fileExists(atPath: fixtureSource.path), "Missing fixture \(fixture.label)")

            for scheme in PathSchemeCase.all {
                let sourceClone = try cloneAndAugmentSourceFixture(
                    fixtureSource: fixtureSource,
                    slimRelativePaths: fixture.matrixSlimRelativePaths,
                    tempRoot: tempRoot,
                    scenarioName: "\(fixture.label)-\(scheme.id)"
                )
                let destination = tempRoot.appendingPathComponent("dest-\(fixture.label)-\(scheme.id)", isDirectory: true)
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

                let expectedPathScheme = scheme.configuration.corePathScheme.receiptPathSchemeString
                let run = try runLauncherImport(
                    source: sourceClone,
                    destination: destination,
                    label: "\(fixture.label)-\(scheme.id)-first",
                    pathSchemeConfiguration: scheme.configuration,
                    environmentOverrides: [
                        "FYLURO_TEST_FORCE_MISSING_CAPTURE_DATE_RELATIVE_PATHS": "DCIM/E2E_UNSORTED.JPG,PRIVATE/E2E_UNSORTED.MP4",
                    ]
                )

                XCTAssertEqual(run.viewModel.uiState, .success)
                XCTAssertEqual(stringValue(run.summaryData["path_scheme"]), expectedPathScheme, "\(fixture.label)-\(scheme.id) path scheme mismatch")

                let touchedPaths = dictionaryValue(run.summaryData["touched_paths"])
                let writtenFinal = stringArray(touchedPaths["written_final_files"])
                XCTAssertFalse(writtenFinal.isEmpty, "\(fixture.label)-\(scheme.id) should write final files")
                assertFinalPathsConformToScheme(
                    writtenFinalFiles: writtenFinal,
                    destination: destination,
                    scheme: scheme.configuration,
                    label: "\(fixture.label)-\(scheme.id)"
                )
                XCTAssertTrue(writtenFinal.contains(where: { $0.contains("/_unsorted/") }), "\(fixture.label)-\(scheme.id) should include _unsorted placement")
                if scheme.configuration.includeCameraFolder {
                    XCTAssertTrue(writtenFinal.contains(where: { $0.contains("/ilce-7cm2/") }), "\(fixture.label)-\(scheme.id) should include known camera folder")
                }

                let rerun = try runLauncherImport(
                    source: sourceClone,
                    destination: destination,
                    label: "\(fixture.label)-\(scheme.id)-rerun",
                    pathSchemeConfiguration: scheme.configuration,
                    environmentOverrides: [
                        "FYLURO_TEST_FORCE_MISSING_CAPTURE_DATE_RELATIVE_PATHS": "DCIM/E2E_UNSORTED.JPG,PRIVATE/E2E_UNSORTED.MP4",
                    ]
                )

                XCTAssertEqual(rerun.viewModel.uiState, .success)
                XCTAssertTrue(rerun.viewModel.isIdempotentRerun, "\(fixture.label)-\(scheme.id) rerun should be idempotent")
                let rerunTotals = totalsByOutcome(from: rerun.summaryData)
                XCTAssertEqual(intValue(rerunTotals["committed"]), 0)
                XCTAssertGreaterThan(intValue(rerunTotals["duplicate_not_copied"]), 0)

                if fixture.label == "SD_CARD1", scheme.id == "E2E-025" {
                    run.viewModel.openNewFinalMediaDirectories()
                    let mediaWindowCount = run.finder.openedDirectories.count + run.finder.revealedURLs.count
                    XCTAssertGreaterThanOrEqual(mediaWindowCount, 1)
                    XCTAssertLessThanOrEqual(mediaWindowCount, LauncherFinderDirectoryResolver.defaultMaxWindows)

                    run.viewModel.openDestination()
                    run.viewModel.openReceipt()
                    XCTAssertGreaterThanOrEqual(run.finder.revealedURLs.count, 2)
                }
            }
        }
    }
}
