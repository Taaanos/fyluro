import XCTest
@testable import fyluroLauncher
@testable import FyluroCore
import FyluroEngine

@MainActor
extension LauncherCoreTests {
    func testSourceAndDestinationValidation() throws {
        let fileManager = FileManager.default
        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("fyluro-launcher-tests-\(UUID().uuidString)", isDirectory: true)
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
            .appendingPathComponent("fyluro-launcher-viewmodel-\(UUID().uuidString)", isDirectory: true)
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
        viewModel.apply(.scanProgress(
            filesChecked: 210,
            bytesChecked: 44_000_000_000,
            candidates: 40,
            photos: 30,
            photoBytes: 30_000_000_000,
            videos: 10,
            videoBytes: 14_000_000_000,
            audios: 0,
            audioBytes: 0,
            currentPath: "DCIM/100MEDIA/IMG_0040.JPG"
        ))

        viewModel.apply(.scanProgress(
            filesChecked: 12481,
            bytesChecked: 184_000_000_000,
            candidates: 6142,
            photos: 6000,
            photoBytes: 100_000_000_000,
            videos: 142,
            videoBytes: 84_000_000_000,
            audios: 0,
            audioBytes: 0,
            currentPath: "DCIM/102MSDCF/DSC01234.ARW"
        ))

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
    func testViewModelAppliesScanCompletedEvent() {
        let viewModel = LauncherViewModel(
            destinationRemembering: StubLauncherDestinationRemembering(initialPath: nil),
            destinationDefaulting: StubLauncherDestinationDefaulting(path: nil)
        )

        viewModel.apply(.scanCompleted(
            candidates: 31,
            photos: 0,
            photoBytes: 0,
            videos: 31,
            videoBytes: 2_857_304_064,
            audios: 0,
            audioBytes: 0
        ))

        XCTAssertEqual(viewModel.scannedCandidateCount, 31)
        XCTAssertEqual(viewModel.scannedPhotoCount, 0)
        XCTAssertEqual(viewModel.scannedVideoCount, 31)
        XCTAssertEqual(viewModel.scannedTotalBytes, 2_857_304_064)
        XCTAssertEqual(viewModel.setupInventory?.videoCount, 31)
        XCTAssertEqual(viewModel.setupInventory?.totalBytes, 2_857_304_064)
    }

    @MainActor
    func testViewModelSurfacesFilmModeRAWSkipCountAsCompletionNotice() {
        let viewModel = LauncherViewModel(
            destinationRemembering: StubLauncherDestinationRemembering(initialPath: nil),
            destinationDefaulting: StubLauncherDestinationDefaulting(path: nil)
        )

        XCTAssertNil(viewModel.filmModeRawSkipNoticeText)

        let counts = IngestCounts(
            candidates: 1,
            photos: 1,
            videos: 0,
            copied: 1,
            verified: 1,
            committed: 1,
            duplicateNotCopied: 0,
            conflictsRenamed: 0,
            errors: 0
        )
        let result = IngestSessionResult(
            sessionID: "test-session",
            finalStatus: "completed",
            dryRun: false,
            receiptPath: "/tmp/receipt.ndjson",
            receiptSink: "destination",
            stagingSessionPath: "/tmp/staging",
            pdfSummaryPath: nil,
            failurePhase: nil,
            failureReason: nil,
            firstErrors: [],
            phaseTimings: [],
            counts: counts,
            idempotency: IngestIdempotency(classification: "new_files_committed", newFilesCommitted: 1, duplicatesSkipped: 0),
            filmModeExifApplied: 0,
            filmModeExifSkipped: 1
        )

        viewModel.apply(.finished(result))

        XCTAssertEqual(
            viewModel.filmModeRawSkipNoticeText,
            "Film Mode: 1 RAW file kept its original camera metadata — RAW files are not supported, but folder placement is still correct."
        )
    }

    @MainActor
    func testViewModelCompletionStatsUseFinishedCountsAndResetOnNewCard() {
        let viewModel = LauncherViewModel(
            destinationRemembering: StubLauncherDestinationRemembering(initialPath: nil),
            destinationDefaulting: StubLauncherDestinationDefaulting(path: nil)
        )
        viewModel.scannedTotalBytes = 2_000_000
        let counts = IngestCounts(
            candidates: 9,
            photos: 6,
            videos: 3,
            audios: 0,
            copied: 9,
            verified: 9,
            committed: 7,
            duplicateNotCopied: 2,
            conflictsRenamed: 1,
            errors: 0
        )
        let result = IngestSessionResult(
            sessionID: "test-session",
            finalStatus: "completed",
            dryRun: false,
            receiptPath: "/tmp/receipt.ndjson",
            receiptSink: "destination",
            stagingSessionPath: "/tmp/staging",
            pdfSummaryPath: nil,
            failurePhase: nil,
            failureReason: nil,
            firstErrors: [],
            phaseTimings: [IngestPhaseTiming(phase: .copy, milliseconds: 65_000)],
            counts: counts,
            idempotency: IngestIdempotency(classification: "new_files_committed", newFilesCommitted: 7, duplicatesSkipped: 2),
            filmModeExifApplied: 0,
            filmModeExifSkipped: 0
        )

        viewModel.apply(.finished(result))

        let titles = viewModel.completionStats.map(\.title)
        XCTAssertEqual(titles, ["Added to library", "Already in library", "Size", "Photos", "Videos", "Renamed", "Elapsed"])
        let values = Dictionary(uniqueKeysWithValues: viewModel.completionStats.map { ($0.title, $0.value) })
        XCTAssertEqual(values["Added to library"], "7")
        XCTAssertEqual(values["Already in library"], "2")
        XCTAssertEqual(values["Photos"], "6")
        XCTAssertEqual(values["Videos"], "3")
        XCTAssertEqual(values["Renamed"], "1")
        XCTAssertEqual(values["Elapsed"], "1m 05s")

        viewModel.uiState = .success
        viewModel.importAnotherCard()
        XCTAssertEqual(viewModel.finalizedPhotoCount, 0)
        XCTAssertEqual(viewModel.finalizedVideoCount, 0)
        XCTAssertEqual(viewModel.finalizedAudioCount, 0)
        XCTAssertEqual(viewModel.finalizedConflictsRenamedCount, 0)
    }

    @MainActor
    func testViewModelCompletionFilmModeTextLeadsWithFilmCamera() {
        let viewModel = LauncherViewModel(
            destinationRemembering: StubLauncherDestinationRemembering(initialPath: nil),
            destinationDefaulting: StubLauncherDestinationDefaulting(path: nil)
        )
        XCTAssertNil(viewModel.completionFilmModeText)

        viewModel.filmModeEnabled = true
        viewModel.filmModeConfiguration = FilmModeOverride(year: 1998, month: 3, camera: "Nikon F3", filmStock: "Portra 400", iso: nil, creator: nil, copyright: nil)

        XCTAssertEqual(
            viewModel.completionFilmModeText,
            "Film Mode — recorded as shot on Nikon F3 · Portra 400 · Mar 1998"
        )
    }

    @MainActor
    func testViewModelRecordsScanErrorsAsCompletionWarning() {
        let viewModel = LauncherViewModel(
            destinationRemembering: StubLauncherDestinationRemembering(initialPath: nil),
            destinationDefaulting: StubLauncherDestinationDefaulting(path: nil)
        )

        XCTAssertFalse(viewModel.hasRecordedErrors)

        viewModel.apply(.errorRecorded(
            phase: .scan,
            message: "File is not readable",
            paths: ["/Volumes/SD_CARD1/DCIM/IMG_0083.DNG"]
        ))

        XCTAssertTrue(viewModel.hasRecordedErrors)
        XCTAssertEqual(viewModel.completionWarningTitle, "1 file could not be copied")
        XCTAssertEqual(
            viewModel.completionWarningEntries,
            [LauncherCompletionWarningEntry(path: "/Volumes/SD_CARD1/DCIM/IMG_0083.DNG", message: "File is not readable")]
        )
    }

    @MainActor
    func testViewModelDeduplicatesAndPluralizesManyScanErrors() {
        let viewModel = LauncherViewModel(
            destinationRemembering: StubLauncherDestinationRemembering(initialPath: nil),
            destinationDefaulting: StubLauncherDestinationDefaulting(path: nil)
        )

        for index in 0..<100 {
            viewModel.apply(.errorRecorded(
                phase: .scan,
                message: "File is not readable",
                paths: ["/Volumes/SD_CARD1/DCIM/IMG_\(index).DNG"]
            ))
        }
        // Duplicate path/message pair should not be double-counted.
        viewModel.apply(.errorRecorded(phase: .scan, message: "File is not readable", paths: ["/Volumes/SD_CARD1/DCIM/IMG_0.DNG"]))

        XCTAssertEqual(viewModel.completionWarningEntries.count, 100)
        XCTAssertEqual(viewModel.completionWarningTitle, "100 files could not be copied")
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
            .appendingPathComponent("fyluro-launcher-overlap-\(UUID().uuidString)", isDirectory: true)
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
            .appendingPathComponent("fyluro-launcher-live-inventory-\(UUID().uuidString)", isDirectory: true)
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
            .appendingPathComponent("fyluro-launcher-package-preview-\(UUID().uuidString)", isDirectory: true)
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
            .appendingPathComponent("fyluro-launcher-import-ready-\(UUID().uuidString)", isDirectory: true)
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

    func testViewModelShowsDestinationFreeSpaceOnceSourceScanReady() throws {
        let fileManager = FileManager.default
        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("fyluro-launcher-space-check-sufficient-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempRoot) }

        let source = tempRoot.appendingPathComponent("source", isDirectory: true)
        let destination = tempRoot.appendingPathComponent("dest", isDirectory: true)
        try fileManager.createDirectory(at: source, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)

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
            progressSnapshots: [],
            finalPreparation: makeIngestPreparation(summary: finalSummary),
            pauseAfterProgress: 0
        )
        let viewModel = LauncherViewModel(
            destinationRemembering: StubLauncherDestinationRemembering(initialPath: nil),
            destinationDefaulting: StubLauncherDestinationDefaulting(path: nil),
            sourceScanner: sourceScanner
        )

        viewModel.sourcePath = source.path
        viewModel.destinationPath = destination.path

        XCTAssertTrue(waitUntil {
            viewModel.destinationSpaceCheck != nil
        })

        XCTAssertTrue(viewModel.destinationFreeSpaceRowText?.contains("free") ?? false)
        XCTAssertNil(viewModel.destinationSpaceWarningText)
        XCTAssertTrue(viewModel.isImportReady)
    }

    func testViewModelBlocksImportOnInsufficientDestinationSpaceUntilOverridden() throws {
        let fileManager = FileManager.default
        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("fyluro-launcher-space-check-insufficient-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempRoot) }

        let source = tempRoot.appendingPathComponent("source", isDirectory: true)
        let destination = tempRoot.appendingPathComponent("dest", isDirectory: true)
        try fileManager.createDirectory(at: source, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)

        let hugeByteCount = Int64.max / 2
        let finalSummary = makeScanSummary(
            itemCount: 1,
            photoCount: 1,
            videoCount: 0,
            totalBytes: hugeByteCount,
            distribution: [
                CameraDistributionEntry(cameraLabel: "canon-eos-r5", fileCount: 1),
            ]
        )

        let sourceScanner = StubLauncherSourceScanner(
            progressSnapshots: [],
            finalPreparation: makeIngestPreparation(summary: finalSummary),
            pauseAfterProgress: 0
        )
        let viewModel = LauncherViewModel(
            destinationRemembering: StubLauncherDestinationRemembering(initialPath: nil),
            destinationDefaulting: StubLauncherDestinationDefaulting(path: nil),
            sourceScanner: sourceScanner
        )

        viewModel.sourcePath = source.path
        viewModel.destinationPath = destination.path

        XCTAssertTrue(waitUntil {
            viewModel.destinationSpaceWarningText != nil
        })

        XCTAssertTrue(viewModel.destinationSpaceWarningText?.contains("insufficient free space") ?? false)
        XCTAssertTrue(viewModel.canStart, "Path validity alone should still be satisfied")
        XCTAssertTrue(viewModel.isDestinationSpaceBlocking)
        XCTAssertFalse(viewModel.isImportReady, "Insufficient destination space must block Import readiness by default")

        viewModel.acceptDestinationSpaceOverride()

        XCTAssertFalse(viewModel.isDestinationSpaceBlocking)
        XCTAssertTrue(viewModel.isImportReady, "Accepting the override should unblock Import readiness")
    }

    func testViewModelResetsDestinationSpaceOverrideWhenDestinationPathChanges() throws {
        let fileManager = FileManager.default
        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("fyluro-launcher-space-check-override-reset-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempRoot) }

        let source = tempRoot.appendingPathComponent("source", isDirectory: true)
        let destination = tempRoot.appendingPathComponent("dest", isDirectory: true)
        let otherDestination = tempRoot.appendingPathComponent("dest2", isDirectory: true)
        try fileManager.createDirectory(at: source, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: otherDestination, withIntermediateDirectories: true)

        let hugeByteCount = Int64.max / 2
        let finalSummary = makeScanSummary(
            itemCount: 1,
            photoCount: 1,
            videoCount: 0,
            totalBytes: hugeByteCount,
            distribution: [
                CameraDistributionEntry(cameraLabel: "canon-eos-r5", fileCount: 1),
            ]
        )

        let sourceScanner = StubLauncherSourceScanner(
            progressSnapshots: [],
            finalPreparation: makeIngestPreparation(summary: finalSummary),
            pauseAfterProgress: 0
        )
        let viewModel = LauncherViewModel(
            destinationRemembering: StubLauncherDestinationRemembering(initialPath: nil),
            destinationDefaulting: StubLauncherDestinationDefaulting(path: nil),
            sourceScanner: sourceScanner
        )

        viewModel.sourcePath = source.path
        viewModel.destinationPath = destination.path

        XCTAssertTrue(waitUntil {
            viewModel.isDestinationSpaceBlocking
        })

        viewModel.acceptDestinationSpaceOverride()
        XCTAssertTrue(viewModel.isImportReady)

        viewModel.destinationPath = otherDestination.path

        XCTAssertFalse(viewModel.destinationSpaceOverrideAccepted, "Changing the destination should re-arm the block")
        XCTAssertTrue(waitUntil {
            viewModel.isDestinationSpaceBlocking
        })
        XCTAssertFalse(viewModel.isImportReady)
    }

    /// Feeds a realistic event sequence through the view model and asserts the
    /// progress fraction never decreases — guards against the "jumpy bar"
    /// (e.g. the old verify-band snap or a backward move at phase transitions).
    func testProgressFractionIsMonotonicAcrossAFullRun() {
        let viewModel = LauncherViewModel(
            destinationRemembering: StubLauncherDestinationRemembering(initialPath: nil),
            destinationDefaulting: StubLauncherDestinationDefaulting(path: nil)
        )
        viewModel.uiState = .running
        viewModel.lastPreviewSummary = LauncherSourceScopeSummary(
            itemCount: 2, photoCount: 2, videoCount: 0, totalBytes: 1000
        )

        var last = -1.0
        func step(_ event: IngestEvent) {
            viewModel.apply(event)
            let fraction = viewModel.importingProgressFraction
            XCTAssertGreaterThanOrEqual(
                fraction, last - 0.0001,
                "progress went backward to \(fraction) after \(event)"
            )
            last = fraction
        }

        // Scan: candidates discovered incrementally.
        step(.scanProgress(filesChecked: 1, bytesChecked: 400, candidates: 1, photos: 1, photoBytes: 400, videos: 0, videoBytes: 0, audios: 0, audioBytes: 0, currentPath: "DCIM/A.JPG"))
        step(.scanProgress(filesChecked: 2, bytesChecked: 1000, candidates: 2, photos: 2, photoBytes: 1000, videos: 0, videoBytes: 0, audios: 0, audioBytes: 0, currentPath: "DCIM/B.JPG"))
        step(.scanCompleted(candidates: 2, photos: 2, photoBytes: 1000, videos: 0, videoBytes: 0, audios: 0, audioBytes: 0))
        // Plan.
        step(.phaseChanged(.plan))
        step(.planCompleted(plannedStageAndCommit: 2, duplicatesSkipped: 0, conflictsRenamed: 0, bytesToCopy: 1000, directoriesToCreate: []))
        // Pass 1: Copy all planned files to staging.
        step(.phaseChanged(.copy))
        step(.fileCopyStarted(path: "DCIM/A.JPG", expectedBytes: 500))
        step(.fileCopyProgress(path: "DCIM/A.JPG", bytesCopied: 250, expectedBytes: 500))
        step(.fileCopyProgress(path: "DCIM/A.JPG", bytesCopied: 500, expectedBytes: 500))
        step(.fileCopyStarted(path: "DCIM/B.JPG", expectedBytes: 500))
        step(.fileCopyProgress(path: "DCIM/B.JPG", bytesCopied: 500, expectedBytes: 500))
        XCTAssertEqual(viewModel.importingProgressText, "2 of 2 items copied")
        // Pass 2: Verify all staged files from physical storage.
        step(.phaseChanged(.verify))
        step(.fileVerifyProgress(path: "DCIM/A.JPG", bytesVerified: 250, expectedBytes: 500))
        XCTAssertEqual(viewModel.importingProgressText, "0 of 2 items verified")
        step(.fileVerifyProgress(path: "DCIM/A.JPG", bytesVerified: 500, expectedBytes: 500))
        step(.fileVerified(path: "DCIM/A.JPG"))
        XCTAssertEqual(viewModel.importingProgressText, "1 of 2 items verified")
        step(.fileVerifyProgress(path: "DCIM/B.JPG", bytesVerified: 500, expectedBytes: 500))
        step(.fileVerified(path: "DCIM/B.JPG"))
        XCTAssertEqual(viewModel.importingProgressText, "2 of 2 items verified")
        // Commit (real-time per file).
        step(.phaseChanged(.commit))
        step(.fileCommitted(path: "DCIM/A.JPG", finalPath: "/dest/A.JPG"))
        step(.fileCommitted(path: "DCIM/B.JPG", finalPath: "/dest/B.JPG"))
        step(.phaseChanged(.finalize))

        // The copy->verify->commit transitions must be monotonic and reach at least 0.86.
        XCTAssertGreaterThanOrEqual(last, 0.86 - 0.0001)
    }

    func testViewModelSurfacesFailedScanReasonAndDimsImport() throws {
        struct UnexpectedScanError: Error {}

        final class FailingLauncherSourceScanner: LauncherSourceScanning {
            let error: Error
            init(error: Error) { self.error = error }
            func scan(
                sourcePath: String,
                mode: SourceScanMode,
                metadataCache: (any SourceScanMetadataCaching)?,
                progress: (@Sendable (ScanProgressSnapshot) -> Void)?
            ) throws -> IngestPreparation {
                throw error
            }
        }

        let fileManager = FileManager.default
        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("fyluro-launcher-scan-failed-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempRoot) }

        let source = tempRoot.appendingPathComponent("source", isDirectory: true)
        let destination = tempRoot.appendingPathComponent("dest", isDirectory: true)
        try fileManager.createDirectory(at: source, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)

        let viewModel = LauncherViewModel(
            destinationRemembering: StubLauncherDestinationRemembering(initialPath: nil),
            destinationDefaulting: StubLauncherDestinationDefaulting(path: nil),
            sourceScanner: FailingLauncherSourceScanner(error: UnexpectedScanError())
        )

        viewModel.destinationPath = destination.path
        viewModel.sourcePath = source.path

        XCTAssertTrue(waitUntil {
            viewModel.isSourceScanFailed
        })

        XCTAssertNil(viewModel.setupInventory)
        XCTAssertEqual(viewModel.setupInventoryPlaceholderText, "Source scan failed.")
        XCTAssertFalse(viewModel.isImportReady)
    }

    func testViewModelSurfacesEmptyScanMessageWhenReadyWithZeroItems() throws {
        let fileManager = FileManager.default
        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("fyluro-launcher-scan-empty-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempRoot) }

        let source = tempRoot.appendingPathComponent("source", isDirectory: true)
        try fileManager.createDirectory(at: source, withIntermediateDirectories: true)

        let emptySummary = makeScanSummary(
            itemCount: 0,
            photoCount: 0,
            videoCount: 0,
            totalBytes: 0,
            distribution: []
        )
        let sourceScanner = StubLauncherSourceScanner(
            progressSnapshots: [],
            finalPreparation: makeIngestPreparation(summary: emptySummary),
            pauseAfterProgress: 0
        )
        let viewModel = LauncherViewModel(
            destinationRemembering: StubLauncherDestinationRemembering(initialPath: nil),
            destinationDefaulting: StubLauncherDestinationDefaulting(path: nil),
            sourceScanner: sourceScanner
        )

        XCTAssertNil(viewModel.setupEmptySourceMessage)
        viewModel.sourcePath = source.path

        XCTAssertTrue(waitUntil {
            if case .ready = viewModel.sourceScanState { return true }
            return false
        })

        XCTAssertEqual(viewModel.setupInventory?.itemCount, 0)
        XCTAssertEqual(viewModel.setupEmptySourceMessage, "No media found.")
    }

}
