import CryptoKit
import Foundation
import XCTest
@testable import RollKeepCore
@testable import rollkeepLauncher

@MainActor
final class LauncherAppE2ETests: XCTestCase {
    private struct FixtureSource {
        let label: String
        let relativePath: String
        let matrixSlimRelativePaths: [String]

        static let all: [FixtureSource] = [
            FixtureSource(
                label: "SD_CARD1",
                relativePath: "Tests/TestingDirs/SD_CARD1",
                matrixSlimRelativePaths: [
                    "DCIM/IMG_8483.HEIC",
                    "DCIM/IMG_8497.HEIC",
                ]
            ),
            FixtureSource(
                label: "SD_CARD2",
                relativePath: "Tests/TestingDirs/SD_CARD2",
                matrixSlimRelativePaths: [
                    "DCIM/DSC01930.JPG",
                    "PRIVATE/20250823_C2851.MOV",
                ]
            ),
        ]
    }

    private struct PathSchemeCase {
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
        ]
    }

    private struct RunArtifacts {
        let viewModel: LauncherViewModel
        let finder: StubLauncherFinderOpening
        let receiptPath: String
        let receiptEvents: [[String: Any]]
        let summaryData: [String: Any]
        let destination: URL
        let source: URL
    }

    private struct FileSnapshot: Equatable {
        let sha256: String
        let size: UInt64
        let mtimeNanoseconds: UInt64
    }

    private var repoRoot: URL!
    private var rollkeepBinary: URL!

    override func setUpWithError() throws {
        if ProcessInfo.processInfo.environment["ROLLKEEP_RUN_APP_E2E"] != "1" {
            throw XCTSkip("Set ROLLKEEP_RUN_APP_E2E=1 to run launcher app E2E tests.")
        }

        repoRoot = try resolveRepoRoot()
        rollkeepBinary = repoRoot.appendingPathComponent(".build/debug/rollkeep", isDirectory: false)
        guard FileManager.default.isExecutableFile(atPath: rollkeepBinary.path) else {
            XCTFail("Expected executable rollkeep binary at \(rollkeepBinary.path). Run scripts/app-e2e-launcher-test.sh.")
            return
        }
    }

    func testAppE2EBaselineRerunImmutabilityTimestampsAndWriteAudit() throws {
        let tempRoot = try makeTempDirectory(prefix: "rollkeep-launcher-app-e2e-baseline-")
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        for fixture in FixtureSource.all {
            let source = repoRoot.appendingPathComponent(fixture.relativePath, isDirectory: true)
            XCTAssertTrue(FileManager.default.fileExists(atPath: source.path), "Missing fixture \(fixture.label)")

            let sourceBefore = try fileManifest(root: source)
            let destination = tempRoot.appendingPathComponent("\(fixture.label)-dest", isDirectory: true)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

            let firstRun = try runLauncherImport(
                source: source,
                destination: destination,
                label: "\(fixture.label)-first-pass"
            )

            XCTAssertEqual(firstRun.viewModel.uiState, .success)
            XCTAssertFalse(firstRun.viewModel.receiptPath.isEmpty)
            assertReceiptLifecycle(firstRun.receiptEvents, label: "\(fixture.label)-first-pass")
            assertDestinationConstrainedWrites(summaryData: firstRun.summaryData, destination: destination, label: "\(fixture.label)-first-pass")
            try assertCommittedFileMtimePreservation(summaryData: firstRun.summaryData, label: "\(fixture.label)-first-pass")

            let rerun = try runLauncherImport(
                source: source,
                destination: destination,
                label: "\(fixture.label)-rerun"
            )

            XCTAssertEqual(rerun.viewModel.uiState, .success)
            XCTAssertTrue(rerun.viewModel.isIdempotentRerun, "\(fixture.label)-rerun should report idempotent rerun")
            let rerunTotals = totalsByOutcome(from: rerun.summaryData)
            XCTAssertEqual(intValue(rerunTotals["committed"]), 0, "\(fixture.label)-rerun should commit 0 files")
            XCTAssertGreaterThan(intValue(rerunTotals["duplicate_not_copied"]), 0, "\(fixture.label)-rerun should report duplicates")

            let sourceAfter = try fileManifest(root: source)
            XCTAssertEqual(sourceBefore, sourceAfter, "\(fixture.label) source fixture mutated")
        }
    }

    func testAppE2ERejectsOverlappingPathsBeforeStart() throws {
        let tempRoot = try makeTempDirectory(prefix: "rollkeep-launcher-app-e2e-overlap-")
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let source = tempRoot.appendingPathComponent("source", isDirectory: true)
        let nestedDestination = source.appendingPathComponent("dest", isDirectory: true)
        let siblingDestination = tempRoot.appendingPathComponent("dest", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: nestedDestination, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: siblingDestination, withIntermediateDirectories: true)

        let viewModel = makeViewModel(cliEnvironmentOverrides: [:])
        viewModel.sourcePath = source.path
        viewModel.destinationPath = source.path

        XCTAssertFalse(viewModel.canStart)
        XCTAssertEqual(viewModel.statusMessage, "Source and destination must be different folders with no nesting.")

        viewModel.destinationPath = nestedDestination.path
        XCTAssertFalse(viewModel.canStart)
        XCTAssertEqual(viewModel.statusMessage, "Source and destination must be different folders with no nesting.")

        viewModel.destinationPath = siblingDestination.path
        XCTAssertTrue(waitUntil(timeout: 60) { viewModel.isImportReady })
        XCTAssertTrue(viewModel.canStart)
    }

    func testAppE2EFaultInjectionScenariosAndFailurePostRunActions() throws {
        let tempRoot = try makeTempDirectory(prefix: "rollkeep-launcher-app-e2e-faults-")
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let source = repoRoot.appendingPathComponent("Tests/TestingDirs/SD_CARD1", isDirectory: true)

        let copyFailure = try runLauncherImport(
            source: source,
            destination: tempRoot.appendingPathComponent("copy-fail", isDirectory: true),
            label: "E2E-015-copy",
            environmentOverrides: [
                "ROLLKEEP_TEST_FAIL_COPY_ON_NTH_FILE": "2",
                "ROLLKEEP_TEST_FAIL_COPY_ERROR_MESSAGE": "Simulated destination disconnect during copy",
            ]
        )
        XCTAssertEqual(copyFailure.viewModel.uiState, .failure)
        XCTAssertTrue(copyFailure.viewModel.failureReason.contains("disconnect"), "Expected disconnect failure reason")
        assertErrorPhaseExists(copyFailure.receiptEvents, expectedPhase: "copy", label: "E2E-015-copy")
        copyFailure.viewModel.openDestination()
        copyFailure.viewModel.openReceipt()
        XCTAssertGreaterThanOrEqual(copyFailure.finder.revealedURLs.count, 2)

        let commitFailure = try runLauncherImport(
            source: source,
            destination: tempRoot.appendingPathComponent("commit-fail", isDirectory: true),
            label: "E2E-015-commit",
            environmentOverrides: [
                "ROLLKEEP_TEST_FAIL_COMMIT_ON_NTH_FILE": "1",
                "ROLLKEEP_TEST_FAIL_COMMIT_ERROR_MESSAGE": "Simulated destination disconnect during commit",
            ]
        )
        XCTAssertEqual(commitFailure.viewModel.uiState, .failure)
        assertErrorPhaseExists(commitFailure.receiptEvents, expectedPhase: "commit", label: "E2E-015-commit")
        XCTAssertTrue(eventTypes(in: commitFailure.receiptEvents).contains("FILE_COMMIT_STARTED"))

        let diskFullFailure = try runLauncherImport(
            source: source,
            destination: tempRoot.appendingPathComponent("disk-full-fail", isDirectory: true),
            label: "E2E-016",
            environmentOverrides: [
                "ROLLKEEP_TEST_FAIL_COPY_ON_NTH_FILE": "2",
                "ROLLKEEP_TEST_FAIL_COPY_ERROR_MESSAGE": "No space left on device (simulated ENOSPC)",
            ]
        )
        XCTAssertEqual(diskFullFailure.viewModel.uiState, .failure)
        XCTAssertTrue(diskFullFailure.viewModel.failureReason.contains("No space left on device"))
        assertErrorPhaseExists(diskFullFailure.receiptEvents, expectedPhase: "copy", label: "E2E-016")

        let receiptFailover = try runLauncherImport(
            source: source,
            destination: tempRoot.appendingPathComponent("receipt-failover", isDirectory: true),
            label: "E2E-017",
            environmentOverrides: [
                "ROLLKEEP_TEST_RECEIPT_FAIL_DEST_APPEND_AT_EVENT_INDEX": "3",
            ]
        )
        XCTAssertEqual(receiptFailover.viewModel.uiState, .success)
        let transitions = arrayValue(receiptFailover.summaryData["receipt_sink_transitions"])
        let receiptPaths = arrayValue(receiptFailover.summaryData["receipt_paths"])
        XCTAssertGreaterThanOrEqual(transitions.count, 1, "E2E-017 should record sink transition")
        XCTAssertGreaterThanOrEqual(receiptPaths.count, 2, "E2E-017 should include destination and fallback receipt paths")

        let verifyFailure = try runLauncherImport(
            source: source,
            destination: tempRoot.appendingPathComponent("verify-fail", isDirectory: true),
            label: "E2E-018",
            environmentOverrides: [
                "ROLLKEEP_TEST_CORRUPT_STAGING_BEFORE_VERIFY": "1",
            ]
        )
        XCTAssertEqual(verifyFailure.viewModel.uiState, .failure)
        assertErrorPhaseExists(verifyFailure.receiptEvents, expectedPhase: "verify", label: "E2E-018")
        XCTAssertFalse(eventTypes(in: verifyFailure.receiptEvents).contains("FILE_COMMIT_STARTED"), "E2E-018 should stop before commit")
    }

    func testAppE2ECrashRestartRecoveryAndStopFlow() throws {
        let tempRoot = try makeTempDirectory(prefix: "rollkeep-launcher-app-e2e-recovery-")
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let source = repoRoot.appendingPathComponent("Tests/TestingDirs/SD_CARD1", isDirectory: true)
        let destination = tempRoot.appendingPathComponent("recovery-dest", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        let recoveryViewModel = makeViewModel(cliEnvironmentOverrides: [
            "ROLLKEEP_TEST_SLEEP_BEFORE_COMMIT_SECONDS": "30",
        ])
        recoveryViewModel.sourcePath = source.path
        recoveryViewModel.destinationPath = destination.path
        XCTAssertTrue(waitUntil(timeout: 60) { recoveryViewModel.isImportReady })

        recoveryViewModel.startIngest()

        XCTAssertTrue(waitUntil(timeout: 120) {
            guard let receiptPath = activeReceiptPath(viewModel: recoveryViewModel, destination: destination) else {
                return false
            }
            guard let text = try? String(contentsOfFile: receiptPath, encoding: .utf8) else {
                return false
            }
            return text.contains("\"event_type\":\"FILE_VERIFIED\"") && !text.contains("\"event_type\":\"FILE_COMMIT_STARTED\"")
        }, "Timed out waiting for pre-commit verified state before stop")

        recoveryViewModel.stopIngest()

        XCTAssertTrue(waitUntil(timeout: 120) {
            recoveryViewModel.uiState == .failure && !recoveryViewModel.isRunning
        }, "Stop flow did not finish")
        XCTAssertTrue(recoveryViewModel.wasStoppedByUser)
        XCTAssertEqual(recoveryViewModel.failureTitle, "Import Stopped")

        let stopReceiptPath = resolveReceiptPath(viewModel: recoveryViewModel, destination: destination)
        guard let stopReceiptPath else {
            XCTFail("Stop flow should expose a receipt path")
            return
        }
        let stopEvents = try loadReceiptEvents(path: stopReceiptPath)
        let retainedStagingPath = inferRetainedStagingSessionPath(events: stopEvents, destination: destination)
        XCTAssertNotNil(retainedStagingPath, "Stop flow should retain a staging session path")
        if let retainedStagingPath {
            var isDirectory: ObjCBool = false
            XCTAssertTrue(FileManager.default.fileExists(atPath: retainedStagingPath, isDirectory: &isDirectory))
            XCTAssertTrue(isDirectory.boolValue)
            let retainedFiles = FileManager.default.enumerator(atPath: retainedStagingPath)?
                .allObjects
                .compactMap { $0 as? String }
                .filter { !$0.hasSuffix("/") }
            XCTAssertGreaterThanOrEqual(retainedFiles?.count ?? 0, 1, "Retained staging should include copied files")
        }

        let recoveryRun = try runLauncherImport(
            source: source,
            destination: destination,
            label: "E2E-022-recovery"
        )
        XCTAssertEqual(recoveryRun.viewModel.uiState, .success)
        XCTAssertGreaterThan(intValue(totalsByOutcome(from: recoveryRun.summaryData)["committed"]), 0, "Recovery run should commit files")

        let rerun = try runLauncherImport(
            source: source,
            destination: destination,
            label: "E2E-022-rerun"
        )
        XCTAssertEqual(rerun.viewModel.uiState, .success)
        XCTAssertTrue(rerun.viewModel.isIdempotentRerun)
        let totals = totalsByOutcome(from: rerun.summaryData)
        XCTAssertEqual(intValue(totals["committed"]), 0)
        XCTAssertGreaterThan(intValue(totals["duplicate_not_copied"]), 0)
    }

    func testAppE2EPathSchemeMatrixAcrossSourcesWithSettingsAndPostRunActions() throws {
        let tempRoot = try makeTempDirectory(prefix: "rollkeep-launcher-app-e2e-schemes-")
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
                        "ROLLKEEP_TEST_FORCE_MISSING_CAPTURE_DATE_RELATIVE_PATHS": "DCIM/E2E_UNSORTED.JPG,PRIVATE/E2E_UNSORTED.MP4",
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
                        "ROLLKEEP_TEST_FORCE_MISSING_CAPTURE_DATE_RELATIVE_PATHS": "DCIM/E2E_UNSORTED.JPG,PRIVATE/E2E_UNSORTED.MP4",
                    ]
                )

                XCTAssertEqual(rerun.viewModel.uiState, .success)
                XCTAssertTrue(rerun.viewModel.isIdempotentRerun, "\(fixture.label)-\(scheme.id) rerun should be idempotent")
                let rerunTotals = totalsByOutcome(from: rerun.summaryData)
                XCTAssertEqual(intValue(rerunTotals["committed"]), 0)
                XCTAssertGreaterThan(intValue(rerunTotals["duplicate_not_copied"]), 0)

                if fixture.label == "SD_CARD1", scheme.id == "E2E-025" {
                    run.viewModel.openNewFinalMediaDirectories()
                    run.viewModel.openDestination()
                    run.viewModel.openReceipt()
                    XCTAssertGreaterThanOrEqual(run.finder.openedDirectories.count, 1)
                    XCTAssertGreaterThanOrEqual(run.finder.revealedURLs.count, 2)
                }
            }
        }
    }

    private func runLauncherImport(
        source: URL,
        destination: URL,
        label: String,
        pathSchemeConfiguration: LauncherPathSchemeConfiguration = .default,
        environmentOverrides: [String: String] = [:]
    ) throws -> RunArtifacts {
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        let finder = StubLauncherFinderOpening()
        let memory = StubLauncherDestinationRemembering(initialPath: nil)
        let pathSchemeRemembering = StubLauncherPathSchemeRemembering(initialConfiguration: .default)
        let pathSchemeStore = LauncherPathSchemeSettingsStore(pathSchemeRemembering: pathSchemeRemembering)
        pathSchemeStore.draftConfiguration = pathSchemeConfiguration
        pathSchemeStore.applyDraft()

        let viewModel = LauncherViewModel(
            sourceDefaulting: StubLauncherSourceDefaulting(path: nil),
            destinationRemembering: memory,
            destinationDefaulting: StubLauncherDestinationDefaulting(path: nil),
            pathSchemeSettingsStore: pathSchemeStore,
            sourceScanner: LauncherSharedSourceScanner(),
            finderOpening: finder,
            cliExecutableResolver: { [binary = rollkeepBinary!] in
                binary
            },
            ingestProcessEnvironmentProvider: { [environmentOverrides] in
                var environment = ProcessInfo.processInfo.environment
                for (key, value) in environmentOverrides {
                    environment[key] = value
                }
                return environment
            }
        )

        viewModel.sourcePath = source.path
        viewModel.destinationPath = destination.path
        XCTAssertTrue(waitUntil(timeout: 120) { viewModel.isImportReady }, "\(label): source scan never became import-ready")
        XCTAssertTrue(viewModel.canStart, "\(label): expected canStart before run")

        viewModel.startIngest()
        XCTAssertTrue(waitUntil(timeout: 240) {
            (viewModel.uiState == .success || viewModel.uiState == .failure) && !viewModel.isRunning
        }, "\(label): run did not finish")

        guard let receiptPath = resolveReceiptPath(viewModel: viewModel, destination: destination) else {
            XCTFail("\(label): missing receipt path")
            throw NSError(domain: "LauncherAppE2ETests", code: 1)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: receiptPath), "\(label): receipt path does not exist")

        let events = try loadReceiptEvents(path: receiptPath)
        let summary = try summaryEventData(events: events)
        return RunArtifacts(
            viewModel: viewModel,
            finder: finder,
            receiptPath: receiptPath,
            receiptEvents: events,
            summaryData: summary,
            destination: destination,
            source: source
        )
    }

    private func resolveRepoRoot() throws -> URL {
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        if FileManager.default.fileExists(atPath: cwd.appendingPathComponent("Package.swift").path) {
            return cwd
        }

        let testFile = URL(fileURLWithPath: #filePath)
        let inferred = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: inferred.appendingPathComponent("Package.swift").path) {
            return inferred
        }

        throw NSError(domain: "LauncherAppE2ETests", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not resolve repo root"])
    }

    private func makeTempDirectory(prefix: String) throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let destination = root.appendingPathComponent("\(prefix)\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        return destination
    }

    private func cloneAndAugmentSourceFixture(
        fixtureSource: URL,
        slimRelativePaths: [String],
        tempRoot: URL,
        scenarioName: String
    ) throws -> URL {
        let clone = tempRoot.appendingPathComponent("source-\(scenarioName)", isDirectory: true)
        try FileManager.default.createDirectory(at: clone, withIntermediateDirectories: true)

        for relativePath in slimRelativePaths {
            let sourcePath = fixtureSource.appendingPathComponent(relativePath, isDirectory: false)
            guard FileManager.default.fileExists(atPath: sourcePath.path) else {
                throw NSError(
                    domain: "LauncherAppE2ETests",
                    code: 4,
                    userInfo: [NSLocalizedDescriptionKey: "Missing slim source fixture file: \(sourcePath.path)"]
                )
            }
            let destinationPath = clone.appendingPathComponent(relativePath, isDirectory: false)
            try FileManager.default.createDirectory(
                at: destinationPath.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try FileManager.default.copyItem(at: sourcePath, to: destinationPath)
        }

        let augmentedCaptureDate = Date(timeIntervalSince1970: 1_734_264_000) // 2024-12-15T12:00:00Z
        let augmentedFiles: [String: Data] = [
            "DCIM/E2E_RAW.CR3": Data("rollkeep-e2e-raw-photo-bytes\n".utf8),
            "DCIM/E2E_RAW.XMP": Data("<x:xmpmeta>raw-sidecar</x:xmpmeta>\n".utf8),
            "DCIM/E2E_STD.JPG": Data("rollkeep-e2e-standard-photo-bytes\n".utf8),
            "DCIM/E2E_STD.XMP": Data("<x:xmpmeta>standard-sidecar</x:xmpmeta>\n".utf8),
            "PRIVATE/E2E_VID.MP4": Data("rollkeep-e2e-video-bytes\n".utf8),
            "PRIVATE/E2E_VID.XML": Data("<Metadata><Clip>E2E_VID</Clip></Metadata>\n".utf8),
            "PRIVATE/E2E_KNOWN.MP4": Data("rollkeep-e2e-known-video-bytes\n".utf8),
            "PRIVATE/E2E_KNOWNM01.XML": Data(
                "<NonRealTimeMeta><CreationDate value=\"2024-12-15T12:00:00+00:00\"/><Device manufacturer=\"Sony\" modelName=\"ILCE-7CM2\" serialNo=\"4294967295\"/></NonRealTimeMeta>\n".utf8
            ),
            "DCIM/E2E_UNSORTED.JPG": Data("rollkeep-e2e-unsorted-photo-bytes\n".utf8),
            "PRIVATE/E2E_UNSORTED.MP4": Data("rollkeep-e2e-unsorted-video-bytes\n".utf8),
            "PRIVATE/E2E_UNSORTED.XML": Data("<Metadata><Clip>E2E_UNSORTED</Clip></Metadata>\n".utf8),
        ]

        for (relativePath, payload) in augmentedFiles {
            let path = clone.appendingPathComponent(relativePath, isDirectory: false)
            try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: path.path, contents: payload)
            try FileManager.default.setAttributes([.modificationDate: augmentedCaptureDate], ofItemAtPath: path.path)
        }

        return clone
    }

    private func fileManifest(root: URL) throws -> [String: FileSnapshot] {
        let rootPath = root.path
        var manifest: [String: FileSnapshot] = [:]
        let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )

        while let item = enumerator?.nextObject() as? URL {
            let values = try item.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else {
                continue
            }

            let relativePath = item.path.replacingOccurrences(of: rootPath + "/", with: "")
            let attributes = try FileManager.default.attributesOfItem(atPath: item.path)
            let size = attributes[.size] as? NSNumber ?? 0
            let mtime = attributes[.modificationDate] as? Date ?? Date.distantPast
            let hash = try sha256Hex(path: item)
            manifest[relativePath] = FileSnapshot(
                sha256: hash,
                size: size.uint64Value,
                mtimeNanoseconds: UInt64(mtime.timeIntervalSince1970 * 1_000_000_000)
            )
        }

        return manifest
    }

    private func sha256Hex(path: URL) throws -> String {
        let data = try Data(contentsOf: path)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func waitUntil(
        timeout: TimeInterval,
        pollInterval: TimeInterval = 0.02,
        _ condition: () -> Bool,
        _ message: String? = nil
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return true
            }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(pollInterval))
        }
        if let message {
            XCTFail(message)
        }
        return condition()
    }

    private func resolveReceiptPath(viewModel: LauncherViewModel, destination: URL) -> String? {
        if !viewModel.receiptPath.isEmpty, FileManager.default.fileExists(atPath: viewModel.receiptPath) {
            return viewModel.receiptPath
        }

        if let discovered = activeReceiptPath(viewModel: viewModel, destination: destination) {
            return discovered
        }

        let outputLines = viewModel.outputText.split(separator: "\n").map(String.init)
        for line in outputLines.reversed() where line.hasPrefix("Receipt: ") {
            let parsed = String(line.dropFirst("Receipt: ".count))
            if FileManager.default.fileExists(atPath: parsed) {
                return parsed
            }
        }

        return nil
    }

    private func inferRetainedStagingSessionPath(events: [[String: Any]], destination: URL) -> String? {
        let stagingRoot = destination
            .appendingPathComponent("_ingest_staging", isDirectory: true)
            .standardizedFileURL.path

        for event in events {
            let data = dictionaryValue(event["data"])
            let pathCandidates = [
                stringValue(data["staging_path"]),
                stringValue(data["path"]),
                stringValue(data["source_path"]),
            ]

            for candidate in pathCandidates where !candidate.isEmpty {
                let normalized = URL(fileURLWithPath: candidate).standardizedFileURL.path
                guard normalized.hasPrefix(stagingRoot + "/") else {
                    continue
                }

                let suffix = normalized.dropFirst((stagingRoot + "/").count)
                guard let session = suffix.split(separator: "/").first else {
                    continue
                }
                return stagingRoot + "/" + session
            }
        }

        if let sessions = try? FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: stagingRoot, isDirectory: true),
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            return sessions
                .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
                .map(\.path)
                .sorted()
                .first
        }

        return nil
    }

    private func activeReceiptPath(viewModel: LauncherViewModel, destination: URL) -> String? {
        let receiptsDirectory = destination.appendingPathComponent("_ingest_receipts", isDirectory: true)
        guard FileManager.default.fileExists(atPath: receiptsDirectory.path) else {
            return nil
        }

        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: receiptsDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        let ndjsonEntries = entries.filter { $0.pathExtension == "ndjson" }
        let newest = ndjsonEntries.max { lhs, rhs in
            let leftDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let rightDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return leftDate < rightDate
        }
        return newest?.path
    }

    private func loadReceiptEvents(path: String) throws -> [[String: Any]] {
        let text = try String(contentsOfFile: path, encoding: .utf8)
        var events: [[String: Any]] = []
        for line in text.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            events.append(json)
        }
        return events
    }

    private func summaryEventData(events: [[String: Any]]) throws -> [String: Any] {
        for event in events.reversed() {
            if stringValue(event["event_type"]) == "SUMMARY" {
                return dictionaryValue(event["data"])
            }
        }
        throw NSError(domain: "LauncherAppE2ETests", code: 3, userInfo: [NSLocalizedDescriptionKey: "Missing SUMMARY event"])
    }

    private func assertReceiptLifecycle(_ events: [[String: Any]], label: String) {
        let types = eventTypes(in: events)
        XCTAssertTrue(types.contains("SESSION_STARTED"), "\(label): missing SESSION_STARTED")
        XCTAssertTrue(types.contains("SESSION_FINISHED"), "\(label): missing SESSION_FINISHED")
    }

    private func eventTypes(in events: [[String: Any]]) -> Set<String> {
        Set(events.compactMap { stringValue($0["event_type"]).isEmpty ? nil : stringValue($0["event_type"]) })
    }

    private func assertErrorPhaseExists(_ events: [[String: Any]], expectedPhase: String, label: String) {
        let phases = events
            .filter { stringValue($0["event_type"]) == "ERROR" }
            .map { stringValue($0["phase"]) }
        XCTAssertTrue(phases.contains(expectedPhase), "\(label): expected ERROR phase \(expectedPhase), got \(phases)")
    }

    private func assertCommittedFileMtimePreservation(summaryData: [String: Any], label: String) throws {
        let outcomes = arrayValue(summaryData["per_file_outcomes"])
        var compared = 0
        for outcomeValue in outcomes {
            guard let outcome = outcomeValue as? [String: Any] else {
                continue
            }
            guard stringValue(outcome["outcome"]) == "stage_and_commit",
                  boolValue(outcome["executed"]) == true else {
                continue
            }

            let sourcePath = stringValue(outcome["source_path"])
            let finalPath = stringValue(outcome["final_path"])
            guard !sourcePath.isEmpty, !finalPath.isEmpty else {
                continue
            }

            let sourceAttributes = try FileManager.default.attributesOfItem(atPath: sourcePath)
            let finalAttributes = try FileManager.default.attributesOfItem(atPath: finalPath)
            guard let sourceMTime = sourceAttributes[.modificationDate] as? Date,
                  let finalMTime = finalAttributes[.modificationDate] as? Date else {
                continue
            }

            let delta = abs(sourceMTime.timeIntervalSince1970 - finalMTime.timeIntervalSince1970)
            XCTAssertLessThanOrEqual(delta, 1.0, "\(label): mtime delta too large (\(delta)) for \(finalPath)")
            compared += 1
        }

        XCTAssertGreaterThan(compared, 0, "\(label): expected at least one committed file mtime comparison")
    }

    private func assertDestinationConstrainedWrites(summaryData: [String: Any], destination: URL, label: String) {
        let destinationPath = destination.standardizedFileURL.path
        let touched = dictionaryValue(summaryData["touched_paths"])

        let pathKeys = [
            "created_directories",
            "written_staging_files",
            "written_final_files",
            "written_receipt_files",
            "deleted_paths",
        ]

        for key in pathKeys {
            for path in stringArray(touched[key]) {
                XCTAssertTrue(
                    isPathAllowedByDestinationConstraint(path, destinationPath: destinationPath),
                    "\(label): touched path escaped destination constraints (\(key)): \(path)"
                )
            }
        }

        for moveValue in arrayValue(touched["move_operations"]) {
            guard let move = moveValue as? [String: Any] else {
                continue
            }
            let fromPath = stringValue(move["from"])
            let toPath = stringValue(move["to"])
            XCTAssertTrue(
                isPathAllowedByDestinationConstraint(fromPath, destinationPath: destinationPath),
                "\(label): move.from escaped destination constraints: \(fromPath)"
            )
            XCTAssertTrue(
                isPathAllowedByDestinationConstraint(toPath, destinationPath: destinationPath),
                "\(label): move.to escaped destination constraints: \(toPath)"
            )
        }
    }

    private func isPathAllowedByDestinationConstraint(_ path: String, destinationPath: String) -> Bool {
        guard !path.isEmpty else {
            return false
        }

        let normalizedPath = URL(fileURLWithPath: path, isDirectory: false).standardizedFileURL.path
        let normalizedDestination = URL(fileURLWithPath: destinationPath, isDirectory: true).standardizedFileURL.path
        if normalizedPath == normalizedDestination || normalizedPath.hasPrefix(normalizedDestination + "/") {
            return true
        }

        // Allow receipt failover writes in local temp only.
        if normalizedPath.contains("/rollkeep/_ingest_receipts/") {
            return true
        }

        return false
    }

    private func assertFinalPathsConformToScheme(
        writtenFinalFiles: [String],
        destination: URL,
        scheme: LauncherPathSchemeConfiguration,
        label: String
    ) {
        let destinationPrefix = destination.standardizedFileURL.path + "/"
        for fullPath in writtenFinalFiles {
            XCTAssertTrue(fullPath.hasPrefix(destinationPrefix), "\(label): final path should stay in destination: \(fullPath)")
            let relativePath = String(fullPath.dropFirst(destinationPrefix.count))
            let components = relativePath.split(separator: "/").map(String.init)
            XCTAssertGreaterThanOrEqual(components.count, 3, "\(label): expected at least 3 path components in \(relativePath)")
            if components.isEmpty {
                continue
            }

            var index = 0
            if components[0] == "_unsorted" {
                index = 1
            } else {
                switch scheme.chronologicalLayout {
                case .yearYearMonthCompact:
                    XCTAssertTrue(matchesRegex(components[safe: 0] ?? "", pattern: #"^\d{4}$"#), "\(label): expected year in \(relativePath)")
                    XCTAssertTrue(matchesRegex(components[safe: 1] ?? "", pattern: #"^\d{6}$"#), "\(label): expected YYYYMM in \(relativePath)")
                    index = 2
                case .yearMonthNested:
                    XCTAssertTrue(matchesRegex(components[safe: 0] ?? "", pattern: #"^\d{4}$"#), "\(label): expected year in \(relativePath)")
                    XCTAssertTrue(matchesRegex(components[safe: 1] ?? "", pattern: #"^\d{2}$"#), "\(label): expected MM in \(relativePath)")
                    index = 2
                }
            }

            if scheme.includeCameraFolder {
                XCTAssertGreaterThan(components.count, index + 1, "\(label): missing camera/media path in \(relativePath)")
                let cameraComponent = components[index]
                XCTAssertFalse(cameraComponent.isEmpty, "\(label): empty camera component in \(relativePath)")
                XCTAssertNotEqual(cameraComponent, "Photos")
                XCTAssertNotEqual(cameraComponent, "Videos")
                index += 1
            }

            XCTAssertGreaterThan(components.count, index + 1, "\(label): missing media directory in \(relativePath)")
            let mediaComponent = components[index]
            XCTAssertTrue(mediaComponent == "Photos" || mediaComponent == "Videos", "\(label): unexpected media directory in \(relativePath)")
            index += 1

            if mediaComponent == "Photos" {
                let hasCompressionDirectory = components[safe: index] == "RAW" || components[safe: index] == "Non-RAW"
                if scheme.splitPhotoCompression {
                    XCTAssertTrue(hasCompressionDirectory, "\(label): expected RAW/Non-RAW segment in \(relativePath)")
                    index += 1
                } else {
                    XCTAssertFalse(hasCompressionDirectory, "\(label): unexpected RAW/Non-RAW segment in \(relativePath)")
                }
            } else if mediaComponent == "Videos" {
                XCTAssertFalse(components[safe: index] == "RAW" || components[safe: index] == "Non-RAW", "\(label): videos should not include compression segment")
            }

            XCTAssertEqual(index, components.count - 1, "\(label): expected filename as final path component in \(relativePath)")
        }
    }

    private func totalsByOutcome(from summaryData: [String: Any]) -> [String: Any] {
        dictionaryValue(summaryData["totals_by_outcome"])
    }

    private func makeViewModel(cliEnvironmentOverrides: [String: String]) -> LauncherViewModel {
        LauncherViewModel(
            sourceDefaulting: StubLauncherSourceDefaulting(path: nil),
            destinationRemembering: StubLauncherDestinationRemembering(initialPath: nil),
            destinationDefaulting: StubLauncherDestinationDefaulting(path: nil),
            sourceScanner: LauncherSharedSourceScanner(),
            finderOpening: StubLauncherFinderOpening(),
            cliExecutableResolver: { [binary = rollkeepBinary!] in
                binary
            },
            ingestProcessEnvironmentProvider: { [cliEnvironmentOverrides] in
                var environment = ProcessInfo.processInfo.environment
                for (key, value) in cliEnvironmentOverrides {
                    environment[key] = value
                }
                return environment
            }
        )
    }

    private func stringValue(_ value: Any?) -> String {
        if let value = value as? String {
            return value
        }
        if let number = value as? NSNumber {
            return number.stringValue
        }
        return ""
    }

    private func intValue(_ value: Any?) -> Int {
        if let intValue = value as? Int {
            return intValue
        }
        if let number = value as? NSNumber {
            return number.intValue
        }
        if let value = value as? String, let intValue = Int(value) {
            return intValue
        }
        return 0
    }

    private func boolValue(_ value: Any?) -> Bool {
        if let boolValue = value as? Bool {
            return boolValue
        }
        if let number = value as? NSNumber {
            return number.boolValue
        }
        if let value = value as? String {
            return value == "true" || value == "1"
        }
        return false
    }

    private func dictionaryValue(_ value: Any?) -> [String: Any] {
        value as? [String: Any] ?? [:]
    }

    private func arrayValue(_ value: Any?) -> [Any] {
        value as? [Any] ?? []
    }

    private func stringArray(_ value: Any?) -> [String] {
        arrayValue(value).compactMap { $0 as? String }
    }

    private func matchesRegex(_ value: String, pattern: String) -> Bool {
        value.range(of: pattern, options: .regularExpression) != nil
    }
}

private struct StubLauncherSourceDefaulting: LauncherSourceDefaulting {
    let path: String?

    func suggestedSourcePath() -> String? {
        path
    }
}

private struct StubLauncherDestinationDefaulting: LauncherDestinationDefaulting {
    let path: String?

    func suggestedDestinationPath() -> String? {
        path
    }
}

private final class StubLauncherDestinationRemembering: LauncherDestinationRemembering {
    private let initialPath: String?
    private(set) var savedPaths: [String] = []

    init(initialPath: String?) {
        self.initialPath = initialPath
    }

    func loadLastDestinationPath() -> String? {
        initialPath
    }

    func saveLastDestinationPath(_ path: String) {
        savedPaths.append(path)
    }
}

private final class StubLauncherPathSchemeRemembering: LauncherPathSchemeRemembering {
    private let initialConfiguration: LauncherPathSchemeConfiguration
    private(set) var savedConfigurations: [LauncherPathSchemeConfiguration] = []

    init(initialConfiguration: LauncherPathSchemeConfiguration) {
        self.initialConfiguration = initialConfiguration
    }

    func loadAppliedPathScheme() -> LauncherPathSchemeConfiguration {
        savedConfigurations.last ?? initialConfiguration
    }

    func saveAppliedPathScheme(_ configuration: LauncherPathSchemeConfiguration) {
        savedConfigurations.append(configuration)
    }
}

private final class StubLauncherFinderOpening: LauncherFinderOpening {
    private(set) var revealedURLs: [[URL]] = []
    private(set) var openedDirectories: [String] = []

    func reveal(_ urls: [URL]) {
        revealedURLs.append(urls)
    }

    @discardableResult
    func openDirectory(_ url: URL) -> Bool {
        openedDirectories.append(url.path)
        return true
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
