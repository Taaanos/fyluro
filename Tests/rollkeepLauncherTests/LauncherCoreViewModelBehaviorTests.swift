import XCTest
@testable import rollkeepLauncher
@testable import RollKeepCore

@MainActor
extension LauncherCoreTests {
    func testSourceAndDestinationValidation() throws {
        let fileManager = FileManager.default
        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("rollkeep-launcher-tests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempRoot) }

        let source = tempRoot.appendingPathComponent("source", isDirectory: true)
        let destination = tempRoot.appendingPathComponent("dest", isDirectory: true)
        let filePath = tempRoot.appendingPathComponent("file.txt", isDirectory: false)

        try fileManager.createDirectory(at: source, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        fileManager.createFile(atPath: filePath.path, contents: Data("x".utf8))

        XCTAssertTrue(LauncherPathValidation.isValidSourcePath(source.path))
        XCTAssertFalse(LauncherPathValidation.isValidSourcePath(filePath.path))

        XCTAssertTrue(LauncherPathValidation.isValidDestinationPath(destination.path))
        XCTAssertFalse(LauncherPathValidation.isValidDestinationPath(filePath.path))
        XCTAssertFalse(LauncherPathValidation.isValidDestinationPath(tempRoot.appendingPathComponent("missing").path))
        XCTAssertTrue(LauncherPathValidation.isValidPathPair(sourcePath: source.path, destinationPath: destination.path))
        XCTAssertNil(LauncherPathValidation.invalidPathPairMessage(sourcePath: source.path, destinationPath: destination.path))

        let nestedDestination = source.appendingPathComponent("library", isDirectory: true)
        try fileManager.createDirectory(at: nestedDestination, withIntermediateDirectories: true)

        XCTAssertFalse(LauncherPathValidation.isValidPathPair(sourcePath: source.path, destinationPath: nestedDestination.path))
        XCTAssertEqual(
            LauncherPathValidation.invalidPathPairMessage(sourcePath: source.path, destinationPath: nestedDestination.path),
            "Source and destination must be different folders with no nesting."
        )
    }

    func testViewModelStateMovesFromIdleToReadyWhenPathsBecomeValid() throws {
        let fileManager = FileManager.default
        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("rollkeep-launcher-viewmodel-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempRoot) }

        let source = tempRoot.appendingPathComponent("source", isDirectory: true)
        let destination = tempRoot.appendingPathComponent("dest", isDirectory: true)
        try fileManager.createDirectory(at: source, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)

        let viewModel = LauncherViewModel(
            destinationRemembering: StubLauncherDestinationRemembering(initialPath: nil),
            destinationDefaulting: StubLauncherDestinationDefaulting(path: nil)
        )
        XCTAssertEqual(viewModel.uiState, .idle)

        viewModel.sourcePath = source.path
        XCTAssertEqual(viewModel.uiState, .idle)

        viewModel.destinationPath = destination.path
        XCTAssertEqual(viewModel.uiState, .ready)
        XCTAssertEqual(viewModel.statusMessage, "Import ready")
        XCTAssertTrue(viewModel.canStart)
    }

    @MainActor
    func testViewModelImportPathDisplayUsesVolumeNameAndStandardizedPath() {
        let viewModel = LauncherViewModel(
            destinationRemembering: StubLauncherDestinationRemembering(initialPath: nil),
            destinationDefaulting: StubLauncherDestinationDefaulting(path: nil)
        )

        viewModel.sourcePath = "/Volumes/SD_CARD1/"
        viewModel.destinationPath = "/Volumes/Media Archive//2026/../2026-library/"

        XCTAssertEqual(viewModel.importSourceDisplayName, "SD_CARD1")
        XCTAssertEqual(viewModel.importSourceDisplayPath, "/Volumes/SD_CARD1")
        XCTAssertEqual(viewModel.importDestinationDisplayName, "2026-library")
        XCTAssertEqual(viewModel.importDestinationDisplayPath, "/Volumes/Media Archive/2026-library")
    }

    @MainActor
    func testViewModelImportPathDisplaySupportsRootPathLabel() {
        let viewModel = LauncherViewModel(
            destinationRemembering: StubLauncherDestinationRemembering(initialPath: nil),
            destinationDefaulting: StubLauncherDestinationDefaulting(path: nil)
        )

        viewModel.sourcePath = "/"
        viewModel.destinationPath = "/Volumes/Archive"

        XCTAssertEqual(viewModel.importSourceDisplayName, "/")
        XCTAssertEqual(viewModel.importSourceDisplayPath, "/")
        XCTAssertEqual(viewModel.importDestinationDisplayName, "Archive")
        XCTAssertEqual(viewModel.importDestinationDisplayPath, "/Volumes/Archive")
    }

    @MainActor
    func testViewModelImportingScanProgressTextShowsDualCountersAndBytes() {
        let viewModel = LauncherViewModel(
            destinationRemembering: StubLauncherDestinationRemembering(initialPath: nil),
            destinationDefaulting: StubLauncherDestinationDefaulting(path: nil)
        )

        viewModel.scannedFilesCheckedCount = 12_481
        viewModel.scannedCandidateCount = 6_142
        viewModel.scannedCheckedBytes = 184_000_000_000

        XCTAssertEqual(
            viewModel.importingScanProgressText,
            "12481 files checked • 6142 import candidates • 184 GB scanned"
        )
    }

    @MainActor
    func testViewModelAppliesScanProgressReceiptStreamWithoutCopyEvents() {
        let viewModel = LauncherViewModel(
            destinationRemembering: StubLauncherDestinationRemembering(initialPath: nil),
            destinationDefaulting: StubLauncherDestinationDefaulting(path: nil)
        )
        var parser = ReceiptEventParser()

        let first = parser.parse(line: """
        {"event_index":2,"event_type":"SCAN_PROGRESS","phase":"scan","data":{"files_checked":210,"bytes_checked":44000000000,"candidate_count":40,"photos":{"count":30,"bytes":30000000000},"videos":{"count":10,"bytes":14000000000},"path":"DCIM/100MEDIA/IMG_0040.JPG"}}
        """)
        viewModel.applyReceiptUpdateForTesting(first)

        let second = parser.parse(line: """
        {"event_index":3,"event_type":"SCAN_PROGRESS","phase":"scan","data":{"files_checked":12481,"bytes_checked":184000000000,"candidate_count":6142,"photos":{"count":6000,"bytes":100000000000},"videos":{"count":142,"bytes":84000000000},"path":"DCIM/102MSDCF/DSC01234.ARW"}}
        """)
        viewModel.applyReceiptUpdateForTesting(second)

        XCTAssertTrue(viewModel.isImportScanPhase)
        XCTAssertEqual(
            viewModel.importingScanProgressText,
            "12481 files checked • 6142 import candidates • 184 GB scanned"
        )
        XCTAssertEqual(
            viewModel.importingScanActivityText,
            "Now scanning: DCIM/102MSDCF/DSC01234.ARW"
        )
    }

    @MainActor
    func testViewModelAppliesScanSummaryFromOutputLogFallback() {
        let viewModel = LauncherViewModel(
            destinationRemembering: StubLauncherDestinationRemembering(initialPath: nil),
            destinationDefaulting: StubLauncherDestinationDefaulting(path: nil)
        )

        viewModel.applyOutputUpdateForTesting(ParsedOutputUpdate(
            phase: .plan,
            scannedCandidateCount: 31,
            scanPhotoCount: 0,
            scanVideoCount: 31,
            scanPhotoBytes: 0,
            scanVideoBytes: 2_857_304_064
        ))

        XCTAssertEqual(viewModel.scannedCandidateCount, 31)
        XCTAssertEqual(viewModel.scannedPhotoCount, 0)
        XCTAssertEqual(viewModel.scannedVideoCount, 31)
        XCTAssertEqual(viewModel.scannedTotalBytes, 2_857_304_064)
        XCTAssertEqual(viewModel.setupInventory?.videoCount, 31)
        XCTAssertEqual(viewModel.setupInventory?.totalBytes, 2_857_304_064)
    }

    @MainActor
    func testViewModelImportPathDisplayFallsBackForEmptyPaths() {
        let viewModel = LauncherViewModel(
            destinationRemembering: StubLauncherDestinationRemembering(initialPath: nil),
            destinationDefaulting: StubLauncherDestinationDefaulting(path: nil)
        )

        viewModel.sourcePath = "   "
        viewModel.destinationPath = ""

        XCTAssertEqual(viewModel.importSourceDisplayName, "Source")
        XCTAssertEqual(viewModel.importSourceDisplayPath, "")
        XCTAssertEqual(viewModel.importDestinationDisplayName, "Destination")
        XCTAssertEqual(viewModel.importDestinationDisplayPath, "")
    }

    @MainActor
    func testViewModelRejectsOverlappingPathsBeforeImportReady() throws {
        let fileManager = FileManager.default
        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("rollkeep-launcher-overlap-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempRoot) }

        let source = tempRoot.appendingPathComponent("card", isDirectory: true)
        let destination = source.appendingPathComponent("library", isDirectory: true)
        try fileManager.createDirectory(at: source, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)

        let viewModel = LauncherViewModel(
            destinationRemembering: StubLauncherDestinationRemembering(initialPath: nil),
            destinationDefaulting: StubLauncherDestinationDefaulting(path: nil)
        )

        viewModel.sourcePath = source.path
        viewModel.destinationPath = destination.path

        XCTAssertEqual(viewModel.uiState, .idle)
        XCTAssertEqual(viewModel.statusMessage, "Source and destination must be different folders with no nesting.")
        XCTAssertFalse(viewModel.canStart)
    }

    @MainActor
    func testViewModelShowsPartialInventoryWhileScanningAndKeepsFinalInventory() throws {
        let fileManager = FileManager.default
        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("rollkeep-launcher-live-inventory-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempRoot) }

        let source = tempRoot.appendingPathComponent("source", isDirectory: true)
        try fileManager.createDirectory(at: source, withIntermediateDirectories: true)

        let partialSnapshot = makeScanProgressSnapshot(
            itemCount: 4,
            photoCount: 3,
            videoCount: 1,
            totalBytes: 3200,
            distribution: [
                CameraDistributionEntry(cameraLabel: "canon-eos-r5", fileCount: 3),
                CameraDistributionEntry(cameraLabel: CameraLabeler.unknownLabel, fileCount: 1),
            ]
        )
        let finalSummary = makeScanSummary(
            itemCount: 4,
            photoCount: 3,
            videoCount: 1,
            totalBytes: 3200,
            distribution: [
                CameraDistributionEntry(cameraLabel: "canon-eos-r5", fileCount: 3),
                CameraDistributionEntry(cameraLabel: CameraLabeler.unknownLabel, fileCount: 1),
            ]
        )

        let sourceScanner = StubLauncherSourceScanner(
            progressSnapshots: [partialSnapshot],
            finalPreparation: makeIngestPreparation(summary: finalSummary),
            pauseAfterProgress: 0.15
        )
        let viewModel = LauncherViewModel(
            destinationRemembering: StubLauncherDestinationRemembering(initialPath: nil),
            destinationDefaulting: StubLauncherDestinationDefaulting(path: nil),
            sourceScanner: sourceScanner
        )

        viewModel.sourcePath = source.path

        XCTAssertTrue(waitUntil {
            viewModel.isSourceScanning && viewModel.setupInventory?.itemCount == 4
        })
        XCTAssertEqual(viewModel.setupInventory?.detectedCameraCount, 1)
        XCTAssertEqual(viewModel.setupInventoryCameraEntries.map(\.displayLabel), ["canon-eos-r5", "Unknown camera"])
        XCTAssertEqual(viewModel.setupInventoryCameraEntries.map(\.fileCount), [3, 1])

        XCTAssertTrue(waitUntil {
            !viewModel.isSourceScanning && viewModel.setupInventory?.itemCount == 4
        })
        XCTAssertEqual(viewModel.setupInventory?.photoCount, 3)
        XCTAssertEqual(viewModel.setupInventory?.videoCount, 1)
        XCTAssertEqual(sourceScanner.requestedModes, [SourceScanMode.preview])
    }

    @MainActor
    func testViewModelPreviewInventoryIncludesVideosInsidePackageDirectories() throws {
        let fileManager = FileManager.default
        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("rollkeep-launcher-package-preview-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempRoot) }

        let source = tempRoot.appendingPathComponent("source", isDirectory: true)
        try fileManager.createDirectory(at: source, withIntermediateDirectories: true)
        let packageURL = source.appendingPathComponent("PRIVATE/AVCHD", isDirectory: true)
        try fileManager.createDirectory(at: packageURL, withIntermediateDirectories: true)
        try fileManager.setAttributes([.extensionHidden: true], ofItemAtPath: packageURL.path)

        let videoURL = source.appendingPathComponent("PRIVATE/AVCHD/BDMV/STREAM/00000.MTS", isDirectory: false)
        try fileManager.createDirectory(at: videoURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let payload = Data(repeating: 0xAB, count: 128)
        XCTAssertTrue(fileManager.createFile(atPath: videoURL.path, contents: payload))

        let viewModel = LauncherViewModel(
            destinationRemembering: StubLauncherDestinationRemembering(initialPath: nil),
            destinationDefaulting: StubLauncherDestinationDefaulting(path: nil),
            sourceScanner: LauncherSharedSourceScanner()
        )

        viewModel.sourcePath = source.path

        XCTAssertTrue(waitUntil {
            !viewModel.isSourceScanning && viewModel.setupInventory?.itemCount == 1
        })
        XCTAssertEqual(viewModel.setupInventory?.photoCount, 0)
        XCTAssertEqual(viewModel.setupInventory?.videoCount, 1)
        XCTAssertEqual(viewModel.setupInventory?.totalBytes, 128)
    }

    @MainActor
    func testViewModelMarksImportReadyOnlyAfterSourceScanCompletes() throws {
        let fileManager = FileManager.default
        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("rollkeep-launcher-import-ready-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempRoot) }

        let source = tempRoot.appendingPathComponent("source", isDirectory: true)
        let destination = tempRoot.appendingPathComponent("dest", isDirectory: true)
        try fileManager.createDirectory(at: source, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)

        let partialSnapshot = makeScanProgressSnapshot(
            itemCount: 4,
            photoCount: 3,
            videoCount: 1,
            totalBytes: 3200,
            distribution: [
                CameraDistributionEntry(cameraLabel: "canon-eos-r5", fileCount: 4),
            ]
        )
        let finalSummary = makeScanSummary(
            itemCount: 4,
            photoCount: 3,
            videoCount: 1,
            totalBytes: 3200,
            distribution: [
                CameraDistributionEntry(cameraLabel: "canon-eos-r5", fileCount: 4),
            ]
        )

        let sourceScanner = StubLauncherSourceScanner(
            progressSnapshots: [partialSnapshot],
            finalPreparation: makeIngestPreparation(summary: finalSummary),
            pauseAfterProgress: 0.15
        )
        let viewModel = LauncherViewModel(
            destinationRemembering: StubLauncherDestinationRemembering(initialPath: nil),
            destinationDefaulting: StubLauncherDestinationDefaulting(path: nil),
            sourceScanner: sourceScanner
        )

        viewModel.sourcePath = source.path
        viewModel.destinationPath = destination.path

        XCTAssertTrue(waitUntil {
            viewModel.isSourceScanning && viewModel.setupInventory?.itemCount == 4
        })
        XCTAssertTrue(viewModel.canStart)
        XCTAssertFalse(viewModel.isImportReady)

        XCTAssertTrue(waitUntil {
            !viewModel.isSourceScanning && viewModel.setupInventory?.itemCount == 4
        })
        XCTAssertTrue(viewModel.isImportReady)
        XCTAssertEqual(sourceScanner.requestedModes, [SourceScanMode.preview])
    }

}
