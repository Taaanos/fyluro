import Foundation
import XCTest
@testable import rollkeepLauncher

@MainActor
extension LauncherCoreTests {
    func testViewModelPreparesDefaultSourceOnLaunch() throws {
        let fileManager = FileManager.default
        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("rollkeep-launcher-default-source-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempRoot) }

        let source = tempRoot.appendingPathComponent("source", isDirectory: true)
        try fileManager.createDirectory(at: source, withIntermediateDirectories: true)

        let viewModel = LauncherViewModel(
            sourceDefaulting: StubLauncherSourceDefaulting(path: source.path),
            destinationRemembering: StubLauncherDestinationRemembering(initialPath: nil),
            destinationDefaulting: StubLauncherDestinationDefaulting(path: nil)
        )
        viewModel.prepareDefaultsOnLaunch()

        XCTAssertEqual(viewModel.sourcePath, source.path)
        XCTAssertEqual(viewModel.uiState, .idle)
        XCTAssertEqual(viewModel.statusMessage, "Choose a writable destination to begin.")
    }

    func testViewModelPreparesDefaultDestinationOnLaunch() throws {
        let fileManager = FileManager.default
        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("rollkeep-launcher-default-destination-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempRoot) }

        let destination = tempRoot.appendingPathComponent("archive", isDirectory: true)
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)

        let viewModel = LauncherViewModel(
            sourceDefaulting: StubLauncherSourceDefaulting(path: nil),
            destinationRemembering: StubLauncherDestinationRemembering(initialPath: nil),
            destinationDefaulting: StubLauncherDestinationDefaulting(path: destination.path)
        )
        viewModel.prepareDefaultsOnLaunch()

        XCTAssertEqual(viewModel.destinationPath, destination.path)
        XCTAssertEqual(viewModel.uiState, .idle)
        XCTAssertEqual(viewModel.statusMessage, "Choose a readable source to begin.")
    }

    func testViewModelRemembersDestinationWhenPathIsSet() throws {
        let fileManager = FileManager.default
        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("rollkeep-launcher-remember-destination-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempRoot) }

        let destination = tempRoot.appendingPathComponent("archive", isDirectory: true)
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)

        let memory = StubLauncherDestinationRemembering(initialPath: nil)
        let viewModel = LauncherViewModel(
            sourceDefaulting: StubLauncherSourceDefaulting(path: nil),
            destinationRemembering: memory,
            destinationDefaulting: StubLauncherDestinationDefaulting(path: nil)
        )

        viewModel.destinationPath = destination.path

        XCTAssertEqual(memory.savedPaths, [destination.path])
    }

    func testViewModelPreparesRememberedDestinationEvenWhenValidationFails() {
        let viewModel = LauncherViewModel(
            sourceDefaulting: StubLauncherSourceDefaulting(path: nil),
            destinationRemembering: StubLauncherDestinationRemembering(initialPath: nil),
            destinationDefaulting: StubLauncherDestinationDefaulting(path: "/Volumes/Archive")
        )

        viewModel.prepareDefaultsOnLaunch()

        XCTAssertEqual(viewModel.destinationPath, "/Volumes/Archive")
    }

    func testViewModelLaunchDefaultDoesNotOverrideExistingSource() throws {
        let fileManager = FileManager.default
        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("rollkeep-launcher-existing-source-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempRoot) }

        let existingSource = tempRoot.appendingPathComponent("existing", isDirectory: true)
        let suggestedSource = tempRoot.appendingPathComponent("suggested", isDirectory: true)
        try fileManager.createDirectory(at: existingSource, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: suggestedSource, withIntermediateDirectories: true)

        let viewModel = LauncherViewModel(
            sourceDefaulting: StubLauncherSourceDefaulting(path: suggestedSource.path),
            destinationRemembering: StubLauncherDestinationRemembering(initialPath: nil),
            destinationDefaulting: StubLauncherDestinationDefaulting(path: nil)
        )
        viewModel.sourcePath = existingSource.path
        viewModel.prepareDefaultsOnLaunch()

        XCTAssertEqual(viewModel.sourcePath, existingSource.path)
    }

    func testViewModelLaunchDefaultDoesNotOverrideExistingDestination() throws {
        let fileManager = FileManager.default
        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("rollkeep-launcher-existing-destination-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempRoot) }

        let existingDestination = tempRoot.appendingPathComponent("existing", isDirectory: true)
        let suggestedDestination = tempRoot.appendingPathComponent("suggested", isDirectory: true)
        try fileManager.createDirectory(at: existingDestination, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: suggestedDestination, withIntermediateDirectories: true)

        let viewModel = LauncherViewModel(
            sourceDefaulting: StubLauncherSourceDefaulting(path: nil),
            destinationRemembering: StubLauncherDestinationRemembering(initialPath: nil),
            destinationDefaulting: StubLauncherDestinationDefaulting(path: suggestedDestination.path)
        )
        viewModel.destinationPath = existingDestination.path
        viewModel.prepareDefaultsOnLaunch()

        XCTAssertEqual(viewModel.destinationPath, existingDestination.path)
    }

    func testViewModelCompletionTextForIdempotentRerun() {
        let viewModel = LauncherViewModel(
            destinationRemembering: StubLauncherDestinationRemembering(initialPath: nil),
            destinationDefaulting: StubLauncherDestinationDefaulting(path: nil)
        )
        viewModel.finalizedCommittedCount = 0
        viewModel.finalizedDuplicateNotCopiedCount = 3
        viewModel.idempotentRerunDetected = true

        XCTAssertTrue(viewModel.isIdempotentRerun)
        XCTAssertEqual(viewModel.completionItemsText, "No new items imported; 3 items already exist in the library")
        XCTAssertEqual(viewModel.completionOutcomeText, "Idempotent rerun confirmed. Existing files were preserved without overwrite.")
    }

    func testViewModelCompletionDurationTextUsesSummaryTiming() {
        let viewModel = LauncherViewModel(
            destinationRemembering: StubLauncherDestinationRemembering(initialPath: nil),
            destinationDefaulting: StubLauncherDestinationDefaulting(path: nil)
        )
        viewModel.finalizedTotalDurationMs = 125_000

        XCTAssertEqual(viewModel.completionDurationText, "Elapsed time 2m 05s")
    }

    func testViewModelImportAnotherCardClearsFinalizedDuration() {
        let viewModel = LauncherViewModel(
            destinationRemembering: StubLauncherDestinationRemembering(initialPath: nil),
            destinationDefaulting: StubLauncherDestinationDefaulting(path: nil)
        )
        viewModel.finalizedTotalDurationMs = 4_200

        viewModel.importAnotherCard()

        XCTAssertNil(viewModel.finalizedTotalDurationMs)
    }

    func testViewModelFiltersOpenableNewFinalMediaDirectories() throws {
        let fileManager = FileManager.default
        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("rollkeep-launcher-open-new-dirs-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempRoot) }

        let destination = tempRoot.appendingPathComponent("dest", isDirectory: true)
        let photos = destination.appendingPathComponent("2026/202601/cam-a/Photos", isDirectory: true)
        let photosRAW = destination.appendingPathComponent("2026/202601/cam-a/Photos/RAW", isDirectory: true)
        let photosNonRAW = destination.appendingPathComponent("2026/202601/cam-a/Photos/Non-RAW", isDirectory: true)
        let videos = destination.appendingPathComponent("2026/202601/cam-a/Videos", isDirectory: true)
        let staging = destination.appendingPathComponent("_ingest_staging/session/2026/202601/cam-a/Photos", isDirectory: true)
        try fileManager.createDirectory(at: photos, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: photosRAW, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: photosNonRAW, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: videos, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)

        let viewModel = LauncherViewModel(
            destinationRemembering: StubLauncherDestinationRemembering(initialPath: nil),
            destinationDefaulting: StubLauncherDestinationDefaulting(path: nil)
        )
        viewModel.destinationPath = destination.path
        viewModel.createdDirectories = [
            photos.path,
            photosRAW.path,
            photosNonRAW.path,
            videos.path,
            staging.path,
            destination.appendingPathComponent("2026/202601/cam-a", isDirectory: true).path,
            tempRoot.appendingPathComponent("outside/Photos", isDirectory: true).path,
        ]

        XCTAssertEqual(viewModel.newFinalMediaDirectories, [photos.path, photosRAW.path, photosNonRAW.path, videos.path].sorted())
        XCTAssertTrue(viewModel.canOpenNewFinalMediaDirectories)
    }

    func testViewModelOpensAllNewFinalMediaDirectories() throws {
        let fileManager = FileManager.default
        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("rollkeep-launcher-open-dirs-action-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempRoot) }

        let destination = tempRoot.appendingPathComponent("dest", isDirectory: true)
        let photos = destination.appendingPathComponent("2026/202601/cam-a/Photos", isDirectory: true)
        let videos = destination.appendingPathComponent("2026/202601/cam-a/Videos", isDirectory: true)
        try fileManager.createDirectory(at: photos, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: videos, withIntermediateDirectories: true)

        let finder = StubLauncherFinderOpening()
        let viewModel = LauncherViewModel(
            destinationRemembering: StubLauncherDestinationRemembering(initialPath: nil),
            destinationDefaulting: StubLauncherDestinationDefaulting(path: nil),
            finderOpening: finder
        )
        viewModel.destinationPath = destination.path
        viewModel.createdDirectories = [videos.path, photos.path]

        viewModel.openNewFinalMediaDirectories()

        XCTAssertEqual(finder.openedDirectories, [photos.path, videos.path])
    }

    func testViewModelOpensSourceInFinderWhenAvailable() throws {
        let fileManager = FileManager.default
        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("rollkeep-launcher-open-source-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempRoot) }

        let source = tempRoot.appendingPathComponent("source", isDirectory: true)
        try fileManager.createDirectory(at: source, withIntermediateDirectories: true)

        let finder = StubLauncherFinderOpening()
        let viewModel = LauncherViewModel(
            destinationRemembering: StubLauncherDestinationRemembering(initialPath: nil),
            destinationDefaulting: StubLauncherDestinationDefaulting(path: nil),
            finderOpening: finder
        )
        viewModel.sourcePath = source.path

        XCTAssertTrue(viewModel.canOpenSource)
        viewModel.openSource()

        XCTAssertEqual(finder.revealedURLs.count, 1)
        XCTAssertEqual(finder.revealedURLs.first?.map(\.path), [source.path])
    }

    func testViewModelOpenSourceSetsStatusWhenUnavailable() {
        let finder = StubLauncherFinderOpening()
        let viewModel = LauncherViewModel(
            destinationRemembering: StubLauncherDestinationRemembering(initialPath: nil),
            destinationDefaulting: StubLauncherDestinationDefaulting(path: nil),
            finderOpening: finder
        )

        viewModel.sourcePath = ""
        XCTAssertFalse(viewModel.canOpenSource)

        viewModel.openSource()

        XCTAssertEqual(viewModel.statusMessage, "Source folder is not available.")
        XCTAssertTrue(finder.revealedURLs.isEmpty)
    }

    func testViewModelOpenDestinationStillRevealsDestinationPath() throws {
        let fileManager = FileManager.default
        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("rollkeep-launcher-open-destination-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempRoot) }

        let destination = tempRoot.appendingPathComponent("dest", isDirectory: true)
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)

        let finder = StubLauncherFinderOpening()
        let viewModel = LauncherViewModel(
            destinationRemembering: StubLauncherDestinationRemembering(initialPath: nil),
            destinationDefaulting: StubLauncherDestinationDefaulting(path: nil),
            finderOpening: finder
        )
        viewModel.destinationPath = destination.path

        XCTAssertTrue(viewModel.canOpenDestination)
        viewModel.openDestination()

        XCTAssertEqual(finder.revealedURLs.count, 1)
        XCTAssertEqual(finder.revealedURLs.first?.map(\.path), [destination.path])
    }

    func testViewModelOpenReceiptPrefersPDFSummaryPath() throws {
        let fileManager = FileManager.default
        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("rollkeep-launcher-open-receipt-pdf-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempRoot) }

        let receipt = tempRoot.appendingPathComponent("run.ndjson", isDirectory: false)
        let pdf = tempRoot.appendingPathComponent("run.summary.pdf", isDirectory: false)
        fileManager.createFile(atPath: receipt.path, contents: Data("{}".utf8))
        fileManager.createFile(atPath: pdf.path, contents: Data("%PDF".utf8))

        let finder = StubLauncherFinderOpening()
        let viewModel = LauncherViewModel(
            destinationRemembering: StubLauncherDestinationRemembering(initialPath: nil),
            destinationDefaulting: StubLauncherDestinationDefaulting(path: nil),
            finderOpening: finder
        )
        viewModel.receiptPath = receipt.path
        viewModel.pdfSummaryPath = pdf.path

        XCTAssertTrue(viewModel.canOpenReceipt)
        viewModel.openReceipt()

        XCTAssertEqual(finder.revealedURLs.count, 1)
        XCTAssertEqual(finder.revealedURLs.first?.map(\.path), [pdf.path])
    }

    func testViewModelDoesNotAllowStartWhileRunning() throws {
        let fileManager = FileManager.default
        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("rollkeep-launcher-running-\(UUID().uuidString)", isDirectory: true)
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
        viewModel.sourcePath = source.path
        viewModel.destinationPath = destination.path
        XCTAssertTrue(viewModel.canStart)

        viewModel.uiState = .running
        XCTAssertFalse(viewModel.canStart)
        XCTAssertTrue(viewModel.isRunning)

        viewModel.sourcePath = ""
        XCTAssertEqual(viewModel.uiState, .running)
    }
}
