import Foundation
import XCTest
@testable import fyluroLauncher
@testable import FyluroCore

@MainActor
extension LauncherCoreTests {
    func testViewModelPreparesDefaultSourceOnLaunch() throws {
        let fileManager = FileManager.default
        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("fyluro-launcher-default-source-\(UUID().uuidString)", isDirectory: true)
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
            .appendingPathComponent("fyluro-launcher-default-destination-\(UUID().uuidString)", isDirectory: true)
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
        // The empty route row and the drop zone already say this, so the screen shows no status line.
        XCTAssertNil(viewModel.setupStatusNoticeText)
    }

    func testViewModelSetupStatusNoticeShowsPathProblemsAndHidesInstructions() {
        let viewModel = LauncherViewModel(
            destinationRemembering: StubLauncherDestinationRemembering(initialPath: nil),
            destinationDefaulting: StubLauncherDestinationDefaulting(path: nil)
        )
        viewModel.statusMessage = "Choose source and destination to begin."
        XCTAssertNil(viewModel.setupStatusNoticeText)

        viewModel.statusMessage = "Source must be a readable folder."
        XCTAssertEqual(viewModel.setupStatusNoticeText, "Source must be a readable folder.")

        viewModel.uiState = .ready
        viewModel.statusMessage = "Import ready"
        XCTAssertNil(viewModel.setupStatusNoticeText)
    }

    func testViewModelRemembersDestinationWhenPathIsSet() throws {
        let fileManager = FileManager.default
        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("fyluro-launcher-remember-destination-\(UUID().uuidString)", isDirectory: true)
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
            .appendingPathComponent("fyluro-launcher-existing-source-\(UUID().uuidString)", isDirectory: true)
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
            .appendingPathComponent("fyluro-launcher-existing-destination-\(UUID().uuidString)", isDirectory: true)
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

    func testViewModelResultRouteStatusFollowsOutcome() {
        let viewModel = LauncherViewModel(
            destinationRemembering: StubLauncherDestinationRemembering(initialPath: nil),
            destinationDefaulting: StubLauncherDestinationDefaulting(path: nil)
        )

        viewModel.uiState = .success
        XCTAssertEqual(viewModel.resultRouteStatus, .complete)

        viewModel.receiptErrors = [ReceiptErrorItem(eventIndex: 1, phase: nil, message: "unreadable", paths: ["/a"])]
        XCTAssertEqual(viewModel.resultRouteStatus, .completeWithWarnings)

        viewModel.uiState = .failure
        XCTAssertEqual(viewModel.resultRouteStatus, .failed)

        viewModel.wasStoppedByUser = true
        XCTAssertEqual(viewModel.resultRouteStatus, .stopped)
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

    func testViewModelImportAnotherCardDisablesFilmMode() {
        let viewModel = LauncherViewModel(
            destinationRemembering: StubLauncherDestinationRemembering(initialPath: nil),
            destinationDefaulting: StubLauncherDestinationDefaulting(path: nil)
        )
        viewModel.applyFilmMode(
            FilmModeOverride(year: 2026, month: 7, camera: "Leica M6", filmStock: "Portra 400", iso: 400, creator: nil, copyright: nil)
        )

        viewModel.importAnotherCard()

        XCTAssertFalse(viewModel.filmModeEnabled)
        XCTAssertNil(viewModel.filmModeConfiguration)
    }

    func testViewModelApplyFilmModeTwiceReplacesTheConfiguration() {
        let viewModel = LauncherViewModel(
            destinationRemembering: StubLauncherDestinationRemembering(initialPath: nil),
            destinationDefaulting: StubLauncherDestinationDefaulting(path: nil)
        )
        viewModel.applyFilmMode(
            FilmModeOverride(year: 1998, month: 9, camera: "Pentax K1000", filmStock: "Kodak Gold 200", iso: 200, creator: nil, copyright: nil)
        )
        viewModel.applyFilmMode(
            FilmModeOverride(year: 1999, month: 1, camera: "Pentax K1000", filmStock: nil, iso: nil, creator: nil, copyright: nil)
        )

        XCTAssertTrue(viewModel.filmModeEnabled)
        XCTAssertEqual(viewModel.filmModeConfiguration?.year, 1999)
        XCTAssertEqual(viewModel.filmModeConfiguration?.month, 1)
        XCTAssertNil(viewModel.filmModeConfiguration?.filmStock)
    }

    func testViewModelFilmModeSummaryStartsWithTheFilmCameraAndSkipsBlankStock() {
        let viewModel = LauncherViewModel(
            destinationRemembering: StubLauncherDestinationRemembering(initialPath: nil),
            destinationDefaulting: StubLauncherDestinationDefaulting(path: nil)
        )
        XCTAssertNil(viewModel.filmModeSummaryText)

        viewModel.applyFilmMode(
            FilmModeOverride(year: 1998, month: 9, camera: "Pentax K1000", filmStock: "Kodak Gold 200", iso: nil, creator: nil, copyright: nil)
        )
        let month = Calendar.current.shortMonthSymbols[8]
        XCTAssertEqual(viewModel.filmModeSummaryText, "shot on Pentax K1000 · Kodak Gold 200 · \(month) 1998")

        viewModel.applyFilmMode(
            FilmModeOverride(year: 1998, month: 9, camera: "Pentax K1000", filmStock: nil, iso: nil, creator: nil, copyright: nil)
        )
        XCTAssertEqual(viewModel.filmModeSummaryText, "shot on Pentax K1000 · \(month) 1998")

        viewModel.disableFilmMode()
        XCTAssertNil(viewModel.filmModeSummaryText)
    }

    func testViewModelImportAnotherCardPreservesFilmModeMemoryForPrefill() {
        let viewModel = LauncherViewModel(
            destinationRemembering: StubLauncherDestinationRemembering(initialPath: nil),
            destinationDefaulting: StubLauncherDestinationDefaulting(path: nil)
        )
        viewModel.applyFilmMode(
            FilmModeOverride(year: 2026, month: 7, camera: "Leica M6", filmStock: "Portra 400", iso: 400, creator: "Jane Doe", copyright: "© 2026 Jane Doe")
        )

        viewModel.importAnotherCard()

        let remembered = viewModel.filmModeRemembering.loadHistory().first
        XCTAssertEqual(remembered?.camera, "Leica M6")
        XCTAssertEqual(remembered?.filmStock, "Portra 400")
        XCTAssertEqual(remembered?.iso, 400)
        XCTAssertEqual(remembered?.creator, "Jane Doe")
        XCTAssertEqual(remembered?.copyright, "© 2026 Jane Doe")
    }

    func testViewModelFiltersOpenableNewFinalMediaDirectories() throws {
        let fileManager = FileManager.default
        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("fyluro-launcher-open-new-dirs-\(UUID().uuidString)", isDirectory: true)
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
            .appendingPathComponent("fyluro-launcher-open-dirs-action-\(UUID().uuidString)", isDirectory: true)
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
            .appendingPathComponent("fyluro-launcher-open-source-\(UUID().uuidString)", isDirectory: true)
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
            .appendingPathComponent("fyluro-launcher-open-destination-\(UUID().uuidString)", isDirectory: true)
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
            .appendingPathComponent("fyluro-launcher-open-receipt-pdf-\(UUID().uuidString)", isDirectory: true)
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
            .appendingPathComponent("fyluro-launcher-running-\(UUID().uuidString)", isDirectory: true)
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

    func testAcceptDroppedSourceSetsSourcePath() throws {
        let fileManager = FileManager.default
        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("fyluro-launcher-drop-source-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempRoot) }

        let source = tempRoot.appendingPathComponent("source", isDirectory: true)
        try fileManager.createDirectory(at: source, withIntermediateDirectories: true)

        let viewModel = LauncherViewModel(
            destinationRemembering: StubLauncherDestinationRemembering(initialPath: nil),
            destinationDefaulting: StubLauncherDestinationDefaulting(path: nil)
        )

        viewModel.acceptDroppedSource([source])

        XCTAssertEqual(viewModel.sourcePath, source.path)
        XCTAssertTrue(viewModel.sourcePathValid)
    }

    func testAcceptDroppedSourceRejectsFileDropAndKeepsSourceEmpty() throws {
        let fileManager = FileManager.default
        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("fyluro-launcher-drop-source-file-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempRoot) }

        let source = tempRoot.appendingPathComponent("source", isDirectory: true)
        try fileManager.createDirectory(at: source, withIntermediateDirectories: true)
        let photo = source.appendingPathComponent("photo.jpg", isDirectory: false)
        fileManager.createFile(atPath: photo.path, contents: Data("x".utf8))

        let viewModel = LauncherViewModel(
            destinationRemembering: StubLauncherDestinationRemembering(initialPath: nil),
            destinationDefaulting: StubLauncherDestinationDefaulting(path: nil)
        )

        viewModel.acceptDroppedSource([photo])

        XCTAssertEqual(viewModel.sourcePath, "")
        XCTAssertEqual(viewModel.statusMessage, "Drop a folder, not a file.")
    }

    func testAcceptDroppedDestinationSetsDestinationPath() throws {
        let fileManager = FileManager.default
        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("fyluro-launcher-drop-destination-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempRoot) }

        let destination = tempRoot.appendingPathComponent("dest", isDirectory: true)
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)

        let viewModel = LauncherViewModel(
            destinationRemembering: StubLauncherDestinationRemembering(initialPath: nil),
            destinationDefaulting: StubLauncherDestinationDefaulting(path: nil)
        )

        viewModel.acceptDroppedDestination([destination])

        XCTAssertEqual(viewModel.destinationPath, destination.path)
        XCTAssertTrue(viewModel.destinationPathValid)
    }

    func testAcceptDroppedSourceNestedUnderDestinationSurfacesOverlapMessage() throws {
        let fileManager = FileManager.default
        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("fyluro-launcher-drop-nested-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempRoot) }

        let destination = tempRoot.appendingPathComponent("dest", isDirectory: true)
        let nestedSource = destination.appendingPathComponent("nested-source", isDirectory: true)
        try fileManager.createDirectory(at: nestedSource, withIntermediateDirectories: true)

        let viewModel = LauncherViewModel(
            destinationRemembering: StubLauncherDestinationRemembering(initialPath: nil),
            destinationDefaulting: StubLauncherDestinationDefaulting(path: nil)
        )
        viewModel.destinationPath = destination.path

        viewModel.acceptDroppedSource([nestedSource])

        XCTAssertEqual(viewModel.sourcePath, nestedSource.path)
        XCTAssertEqual(viewModel.statusMessage, "Source and destination must be different folders with no nesting.")
        XCTAssertEqual(viewModel.uiState, .idle)
    }

    func testAcceptDroppedSourceRejectsMissingPathAndKeepsPriorSource() throws {
        let fileManager = FileManager.default
        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("fyluro-launcher-drop-missing-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempRoot) }

        let source = tempRoot.appendingPathComponent("source", isDirectory: true)
        try fileManager.createDirectory(at: source, withIntermediateDirectories: true)
        let missing = tempRoot.appendingPathComponent("missing", isDirectory: true)

        let viewModel = LauncherViewModel(
            destinationRemembering: StubLauncherDestinationRemembering(initialPath: nil),
            destinationDefaulting: StubLauncherDestinationDefaulting(path: nil)
        )
        viewModel.sourcePath = source.path

        viewModel.acceptDroppedSource([missing])

        XCTAssertEqual(viewModel.sourcePath, source.path)
        XCTAssertEqual(viewModel.statusMessage, "That item no longer exists.")
    }

    func testAcceptDroppedSourceIgnoredWhileRunning() throws {
        let fileManager = FileManager.default
        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("fyluro-launcher-drop-running-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempRoot) }

        let source = tempRoot.appendingPathComponent("source", isDirectory: true)
        let dropped = tempRoot.appendingPathComponent("dropped", isDirectory: true)
        try fileManager.createDirectory(at: source, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: dropped, withIntermediateDirectories: true)

        let viewModel = LauncherViewModel(
            destinationRemembering: StubLauncherDestinationRemembering(initialPath: nil),
            destinationDefaulting: StubLauncherDestinationDefaulting(path: nil)
        )
        viewModel.sourcePath = source.path
        viewModel.uiState = .running

        viewModel.acceptDroppedSource([dropped])

        XCTAssertEqual(viewModel.sourcePath, source.path)
    }

    func testDestinationPanelOffersNewFolder() {
        let panel = LauncherViewModel.makeDestinationPanel()

        XCTAssertTrue(panel.canCreateDirectories)
        XCTAssertTrue(panel.canChooseDirectories)
        XCTAssertFalse(panel.canChooseFiles)
        XCTAssertEqual(panel.prompt, "Use Destination")
    }

    func testSourcePanelDoesNotOfferNewFolder() {
        // A new folder on the card would change the card (I-1).
        let panel = LauncherViewModel.makeSourcePanel()

        XCTAssertFalse(panel.canCreateDirectories)
        XCTAssertTrue(panel.canChooseDirectories)
        XCTAssertFalse(panel.canChooseFiles)
        XCTAssertEqual(panel.prompt, "Use Source")
    }

    func testViewModelAutoSelectsSourceOnMountNotificationWhenEmptyAndIdle() throws {
        let fileManager = FileManager.default
        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("fyluro-launcher-mount-empty-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempRoot) }

        let card = tempRoot.appendingPathComponent("CARD", isDirectory: true)
        try fileManager.createDirectory(at: card, withIntermediateDirectories: true)

        final class DynamicSourceDefaulting: LauncherSourceDefaulting {
            var path: String?
            func suggestedSourcePath() -> String? { path }
        }

        let sourceDefaulting = DynamicSourceDefaulting()
        let notificationCenter = NotificationCenter()
        let viewModel = LauncherViewModel(
            sourceDefaulting: sourceDefaulting,
            destinationRemembering: StubLauncherDestinationRemembering(initialPath: nil),
            destinationDefaulting: StubLauncherDestinationDefaulting(path: nil),
            workspaceNotificationCenter: notificationCenter
        )

        viewModel.prepareDefaultsOnLaunch()
        XCTAssertEqual(viewModel.sourcePath, "")

        sourceDefaulting.path = card.path
        notificationCenter.post(name: NSWorkspace.didMountNotification, object: nil)

        XCTAssertEqual(viewModel.sourcePath, card.path)
    }

    func testViewModelDoesNotOverrideExistingSourceOnMountNotification() throws {
        let fileManager = FileManager.default
        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("fyluro-launcher-mount-existing-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempRoot) }

        let existing = tempRoot.appendingPathComponent("EXISTING", isDirectory: true)
        let mounted = tempRoot.appendingPathComponent("MOUNTED", isDirectory: true)
        try fileManager.createDirectory(at: existing, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: mounted, withIntermediateDirectories: true)

        let notificationCenter = NotificationCenter()
        let viewModel = LauncherViewModel(
            sourceDefaulting: StubLauncherSourceDefaulting(path: mounted.path),
            destinationRemembering: StubLauncherDestinationRemembering(initialPath: nil),
            destinationDefaulting: StubLauncherDestinationDefaulting(path: nil),
            workspaceNotificationCenter: notificationCenter
        )
        viewModel.sourcePath = existing.path

        notificationCenter.post(name: NSWorkspace.didMountNotification, object: nil)

        XCTAssertEqual(viewModel.sourcePath, existing.path)
    }

    func testViewModelIgnoresMountNotificationWhileRunningOrFinished() throws {
        let fileManager = FileManager.default
        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("fyluro-launcher-mount-busy-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempRoot) }

        let card = tempRoot.appendingPathComponent("CARD", isDirectory: true)
        try fileManager.createDirectory(at: card, withIntermediateDirectories: true)

        let notificationCenter = NotificationCenter()
        let viewModel = LauncherViewModel(
            sourceDefaulting: StubLauncherSourceDefaulting(path: card.path),
            destinationRemembering: StubLauncherDestinationRemembering(initialPath: nil),
            destinationDefaulting: StubLauncherDestinationDefaulting(path: nil),
            workspaceNotificationCenter: notificationCenter
        )

        viewModel.uiState = .running
        notificationCenter.post(name: NSWorkspace.didMountNotification, object: nil)
        XCTAssertEqual(viewModel.sourcePath, "")

        viewModel.uiState = .success
        notificationCenter.post(name: NSWorkspace.didMountNotification, object: nil)
        XCTAssertEqual(viewModel.sourcePath, "")
    }

    func testViewModelClearsUnmountedSourceAndSelectsRemainingCard() throws {
        let fileManager = FileManager.default
        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("fyluro-launcher-unmount-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempRoot) }

        let cardA = tempRoot.appendingPathComponent("CARD_A", isDirectory: true)
        let cardB = tempRoot.appendingPathComponent("CARD_B", isDirectory: true)
        try fileManager.createDirectory(at: cardA, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: cardB, withIntermediateDirectories: true)

        final class DynamicSourceDefaulting: LauncherSourceDefaulting {
            var path: String?
            func suggestedSourcePath() -> String? { path }
        }

        let sourceDefaulting = DynamicSourceDefaulting()
        sourceDefaulting.path = cardA.path

        let notificationCenter = NotificationCenter()
        let viewModel = LauncherViewModel(
            sourceDefaulting: sourceDefaulting,
            destinationRemembering: StubLauncherDestinationRemembering(initialPath: nil),
            destinationDefaulting: StubLauncherDestinationDefaulting(path: nil),
            workspaceNotificationCenter: notificationCenter
        )
        viewModel.prepareDefaultsOnLaunch()
        XCTAssertEqual(viewModel.sourcePath, cardA.path)

        sourceDefaulting.path = cardB.path
        notificationCenter.post(
            name: NSWorkspace.didUnmountNotification,
            object: nil,
            userInfo: [NSWorkspace.volumeURLUserInfoKey: cardA]
        )

        XCTAssertEqual(viewModel.sourcePath, cardB.path)
    }
}
