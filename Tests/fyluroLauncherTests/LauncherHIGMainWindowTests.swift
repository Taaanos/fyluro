import AppKit
import Foundation
import FyluroCore
import FyluroEngine
import SwiftUI
import XCTest
@testable import fyluroLauncher

@MainActor
final class LauncherHIGMainWindowTests: XCTestCase {
    private var fixtures: HIGTempFixtures!
    private var priorThroughputGraphObject: Any?
    private var hostedViews: [HostedHIGView] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        priorThroughputGraphObject = UserDefaults.standard.object(forKey: LauncherViewModel.showThroughputGraphDefaultsKey)
        fixtures = try HIGTempFixtures()
    }

    override func tearDownWithError() throws {
        for hosted in hostedViews {
            hosted.close()
        }
        hostedViews.removeAll()

        if let priorThroughputGraphObject {
            UserDefaults.standard.set(priorThroughputGraphObject, forKey: LauncherViewModel.showThroughputGraphDefaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: LauncherViewModel.showThroughputGraphDefaultsKey)
        }

        fixtures?.cleanup()
        fixtures = nil
        try super.tearDownWithError()
    }

    private func makeMainContentView(
        _ viewModel: LauncherViewModel,
        cameraCatalogStore: LauncherCameraCatalogStore? = nil
    ) -> LauncherContentView {
        let store = cameraCatalogStore ?? LauncherCameraCatalogStore(
            remembering: StubCameraCatalogRemembering(.missing),
            preference: StubCameraLabelsPreference(isEnabled: false)
        )
        return LauncherContentView(viewModel: viewModel, cameraCatalogStore: store)
    }

    private func hostMainWindow(
        _ viewModel: LauncherViewModel,
        contentView: LauncherContentView? = nil
    ) -> HostedHIGView {
        let resolvedView = contentView ?? makeMainContentView(viewModel)
        let hosted = HostedHIGView(
            width: LauncherWindowMetrics.idealWidth,
            title: AppBrand.name,
            subtitle: viewModel.windowSubtitle
        ) {
            resolvedView
        }
        hostedViews.append(hosted)
        return hosted
    }

    private func hostUtilityPanel<Content: View>(
        width: CGFloat = LauncherWindowMetrics.idealWidth,
        @ViewBuilder content: () -> Content
    ) -> HostedHIGView {
        let hosted = HostedHIGView(width: width, title: AppBrand.name) {
            content()
                .frame(width: width, alignment: .topLeading)
        }
        hostedViews.append(hosted)
        return hosted
    }

    func testEmptySourcePanelLayoutAndFooterHIG() {
        let viewModel = configureEmptySourceViewModel()
        let hosted = hostMainWindow(viewModel)

        LauncherHIGTestHarness.assertNoHorizontalOverflow(hosted, maxWidth: LauncherWindowMetrics.idealWidth, context: "Empty source")
        XCTAssertFalse(viewModel.isImportReady)
        XCTAssertEqual(hosted.window.subtitle, "")

        let route = LauncherSetupRoutePanel(viewModel: viewModel)
        XCTAssertEqual(route.sourceButtonTitle, "Choose…")
        XCTAssertEqual(route.destinationButtonTitle, "Change…")
        LauncherHIGTestHarness.assertEllipsisConvention(
            titles: [route.sourceButtonTitle, route.destinationButtonTitle, "Film Mode…", "Import"],
            context: "Empty source"
        )
    }

    func testSetupReadyShortAndLongCameraListLayoutAndFooterHIG() {
        let shortVM = configureSetupReadyViewModel(cameraCount: 3, sidecarCount: 3)
        let shortHost = hostMainWindow(shortVM)

        LauncherHIGTestHarness.assertNoHorizontalOverflow(shortHost, maxWidth: LauncherWindowMetrics.idealWidth, context: "Setup ready (3 cameras)")
        XCTAssertTrue(shortVM.isImportReady)
        let route = LauncherSetupRoutePanel(viewModel: shortVM)
        XCTAssertEqual(route.sourceButtonTitle, "Change…")
        XCTAssertEqual(route.destinationButtonTitle, "Change…")
        LauncherHIGTestHarness.assertEllipsisConvention(
            titles: [route.sourceButtonTitle, route.destinationButtonTitle, "Film Mode…", "Import"],
            context: "Setup ready (3 cameras)"
        )

        let tenVM = configureSetupReadyViewModel(cameraCount: 10, sidecarCount: 3)
        let tenHost = hostMainWindow(tenVM)
        LauncherHIGTestHarness.assertNoHorizontalOverflow(tenHost, maxWidth: LauncherWindowMetrics.idealWidth, context: "Setup ready (10 cameras)")

        let twentyVM = configureSetupReadyViewModel(cameraCount: 20, sidecarCount: 3)
        let twentyHost = hostMainWindow(twentyVM)
        LauncherHIGTestHarness.assertNoHorizontalOverflow(twentyHost, maxWidth: LauncherWindowMetrics.idealWidth, context: "Setup ready (20 cameras)")

        let shortHeight = shortHost.measuredFittingSize.height
        let tenHeight = tenHost.measuredFittingSize.height
        let twentyHeight = twentyHost.measuredFittingSize.height

        XCTAssertGreaterThan(tenHeight, shortHeight + 10.0)
        XCTAssertLessThanOrEqual(tenHeight - shortHeight, LauncherWindowMetrics.cameraInventoryMaxHeight)
        XCTAssertEqual(twentyHeight, tenHeight, accuracy: 2.0)
    }

    func testSetupWithFilmModeActiveShowsSummaryRowAndHidesFooterFilmModeButton() {
        let baseVM = configureSetupReadyViewModel(cameraCount: 2, sidecarCount: 1)
        let baseHost = hostMainWindow(baseVM)

        let filmVM = configureSetupReadyViewModel(cameraCount: 2, sidecarCount: 1)
        filmVM.filmModeState = .enabled(
            FilmModeOverride(
                year: 2026,
                month: 10,
                camera: "Pentax K1000",
                filmStock: "Kodak Portra 400",
                iso: 400,
                creator: nil,
                copyright: nil
            )
        )
        let filmHost = hostMainWindow(filmVM)

        LauncherHIGTestHarness.assertNoHorizontalOverflow(baseHost, maxWidth: LauncherWindowMetrics.idealWidth, context: "Setup base")
        LauncherHIGTestHarness.assertNoHorizontalOverflow(filmHost, maxWidth: LauncherWindowMetrics.idealWidth, context: "Setup Film Mode")
        XCTAssertTrue(filmVM.filmModeEnabled)
        XCTAssertNotNil(filmVM.filmModeSummaryText)
        XCTAssertGreaterThan(filmHost.measuredFittingSize.height, baseHost.measuredFittingSize.height + 20.0)
        LauncherHIGTestHarness.assertEllipsisConvention(
            titles: ["Edit…", "Turn Off", "Import"],
            context: "Setup Film Mode"
        )
    }

    func testImportingHeightStabilityActivityDisclosureAndNonDefaultStopButton() {
        let viewModel = configureImportingViewModel(showActivityGraph: false)
        viewModel.currentFilePath = ""
        let hosted = hostMainWindow(viewModel)
        let heightWithoutFile = hosted.measuredFittingSize.height

        LauncherHIGTestHarness.assertNoHorizontalOverflow(hosted, maxWidth: LauncherWindowMetrics.idealWidth, context: "Importing (collapsed)")
        XCTAssertEqual(hosted.window.subtitle, "Importing 48 items…")
        XCTAssertTrue(viewModel.isRunning)
        LauncherHIGTestHarness.assertEllipsisConvention(titles: ["Stop Import"], context: "Importing")

        viewModel.currentFilePath = "/Volumes/VERY_LONG_CAMERA_CARD_NAME/DCIM/100SONY/DSC09999_EXTENDED_FILENAME.ARW"
        hosted.relayout()
        let heightWithLongFile = hosted.measuredFittingSize.height
        XCTAssertEqual(heightWithLongFile, heightWithoutFile, accuracy: 1.0)

        viewModel.showThroughputGraph = true
        hosted.relayout()
        let heightExpanded = hosted.measuredFittingSize.height
        LauncherHIGTestHarness.assertNoHorizontalOverflow(hosted, maxWidth: LauncherWindowMetrics.idealWidth, context: "Importing (expanded)")
        XCTAssertGreaterThan(heightExpanded, heightWithLongFile + 80.0)

        viewModel.showThroughputGraph = false
        hosted.relayout()
        let heightRestored = hosted.measuredFittingSize.height
        XCTAssertEqual(heightRestored, heightWithLongFile, accuracy: 1.0)
    }

    func testCompleteFreshImportIdempotentRerunAndFilmModeRawNoticeHIG() {
        let freshVM = configureCompleteFreshViewModel()
        let freshHost = hostMainWindow(freshVM)

        let freshSecondary = LauncherContentView.completionSecondaryActions(for: freshVM)
        let freshPrimary = LauncherContentView.completionPrimaryAction(for: freshVM)

        LauncherHIGTestHarness.assertNoHorizontalOverflow(freshHost, maxWidth: LauncherWindowMetrics.idealWidth, context: "Complete (fresh)")
        XCTAssertEqual(freshHost.window.subtitle, "Import Complete")
        XCTAssertEqual(freshSecondary.map(\.title), ["Import Another Card"])
        XCTAssertEqual(freshPrimary.title, "Show in Finder")
        XCTAssertTrue(freshVM.canOpenReceipt)
        LauncherHIGTestHarness.assertResultActionBarSingleRow(
            secondaryActions: freshSecondary,
            primaryAction: freshPrimary,
            context: "Complete (fresh)"
        )
        LauncherHIGTestHarness.assertEllipsisConvention(
            titles: ["Import Another Card", "Show in Finder", "Show Receipt"],
            context: "Complete (fresh)"
        )

        let rerunVM = configureCompleteIdempotentViewModel()
        let rerunHost = hostMainWindow(rerunVM)

        let rerunSecondary = LauncherContentView.completionSecondaryActions(for: rerunVM)
        let rerunPrimary = LauncherContentView.completionPrimaryAction(for: rerunVM)

        LauncherHIGTestHarness.assertNoHorizontalOverflow(rerunHost, maxWidth: LauncherWindowMetrics.idealWidth, context: "Complete (idempotent)")
        XCTAssertTrue(rerunSecondary.isEmpty)
        XCTAssertEqual(rerunPrimary.title, "Import Another Card")
        LauncherHIGTestHarness.assertResultActionBarSingleRow(
            secondaryActions: rerunSecondary,
            primaryAction: rerunPrimary,
            context: "Complete (idempotent)"
        )
    }

    func testEmptyMediaMatchesEmptySourceHeightAndHidesScanPreviewHeader() {
        let emptySourceVM = configureEmptySourceViewModel()
        let emptySourceHost = hostMainWindow(emptySourceVM)

        let emptyMediaVM = configureEmptyMediaViewModel()
        let emptyMediaHost = hostMainWindow(emptyMediaVM)

        LauncherHIGTestHarness.assertNoHorizontalOverflow(emptyMediaHost, maxWidth: LauncherWindowMetrics.idealWidth, context: "Empty media")
        XCTAssertFalse(emptyMediaVM.isImportReady)
        XCTAssertNotNil(emptyMediaVM.setupEmptySourceMessage)
        XCTAssertEqual(
            emptyMediaHost.measuredFittingSize.height,
            emptySourceHost.measuredFittingSize.height,
            accuracy: 4.0
        )
    }

    func testSetupRouteCardStaysHorizontalWithLongPathsAndBlockingErrors() {
        let shortSetupVM = configureSetupReadyViewModel(cameraCount: 2)
        let shortSetupRouteHost = hostUtilityPanel {
            LauncherSetupRoutePanel(viewModel: shortSetupVM)
        }
        LauncherHIGTestHarness.assertNoHorizontalOverflow(shortSetupRouteHost, maxWidth: LauncherWindowMetrics.idealWidth, context: "Setup route (short)")

        let longSourcePath = "/Volumes/" + String(repeating: "VERY_LONG_CAMERA_CARD_", count: 5) + "END"
        let longDestPath = "/Users/photographer/" + String(repeating: "ARCHIVE_LIBRARY_FOLDER_", count: 4) + "MEDIA"

        let longSetupVM = configureSetupReadyViewModel(cameraCount: 2)
        longSetupVM.sourcePath = longSourcePath
        longSetupVM.destinationPath = longDestPath
        LauncherHIGTestHarness.cancelBackgroundTasks(on: longSetupVM)
        let longSetupRouteHost = hostUtilityPanel {
            LauncherSetupRoutePanel(viewModel: longSetupVM)
        }
        LauncherHIGTestHarness.assertNoHorizontalOverflow(longSetupRouteHost, maxWidth: LauncherWindowMetrics.idealWidth, context: "Setup route (long)")
        XCTAssertEqual(
            longSetupRouteHost.measuredFittingSize.height,
            shortSetupRouteHost.measuredFittingSize.height,
            accuracy: 4.0
        )

        let shortImportRouteHost = hostUtilityPanel {
            LauncherImportRoutePanel(
                sourceName: "CARD_A",
                sourcePath: "/Volumes/CARD_A",
                destinationName: "Library",
                destinationPath: "/Users/thanos/Pictures/Library",
                status: .complete
            )
        }
        LauncherHIGTestHarness.assertNoHorizontalOverflow(shortImportRouteHost, maxWidth: LauncherWindowMetrics.idealWidth, context: "Import route (short)")

        let longImportRouteHost = hostUtilityPanel {
            LauncherImportRoutePanel(
                sourceName: String(repeating: "LONGCARD_", count: 6),
                sourcePath: longSourcePath,
                destinationName: String(repeating: "LONGDEST_", count: 6),
                destinationPath: longDestPath,
                status: .failed
            )
        }
        LauncherHIGTestHarness.assertNoHorizontalOverflow(longImportRouteHost, maxWidth: LauncherWindowMetrics.idealWidth, context: "Import route (long)")
        XCTAssertEqual(
            longImportRouteHost.measuredFittingSize.height,
            shortImportRouteHost.measuredFittingSize.height,
            accuracy: 4.0
        )

        let routeErrorVM = configureRouteErrorViewModel()
        let routeErrorMainHost = hostMainWindow(routeErrorVM)
        let routeErrorPanelHost = hostUtilityPanel {
            LauncherSetupRoutePanel(viewModel: routeErrorVM)
        }
        LauncherHIGTestHarness.assertNoHorizontalOverflow(routeErrorMainHost, maxWidth: LauncherWindowMetrics.idealWidth, context: "Blocking route error")
        XCTAssertFalse(routeErrorVM.isImportReady)
        XCTAssertEqual(routeErrorVM.setupRouteErrorText, "Destination must be a writable folder.")
        XCTAssertGreaterThan(
            routeErrorPanelHost.measuredFittingSize.height,
            shortSetupRouteHost.measuredFittingSize.height + 24.0
        )

        let unreadableVM = configureUnreadableSourceViewModel()
        let unreadableHost = hostMainWindow(unreadableVM)
        LauncherHIGTestHarness.assertNoHorizontalOverflow(unreadableHost, maxWidth: LauncherWindowMetrics.idealWidth, context: "Unreadable source")
        XCTAssertFalse(unreadableVM.isImportReady)
        XCTAssertNil(unreadableVM.setupRouteErrorText)
        XCTAssertTrue(unreadableVM.isSourceScanFailed)

        let readyWithoutDropHost = hostMainWindow(shortSetupVM)
        let dropRejectedVM = configureDropRejectedViewModel()
        let dropRejectedHost = hostMainWindow(dropRejectedVM)
        LauncherHIGTestHarness.assertNoHorizontalOverflow(dropRejectedHost, maxWidth: LauncherWindowMetrics.idealWidth, context: "Drop rejected")
        XCTAssertEqual(dropRejectedVM.setupDropNoticeText, "Drop a folder, not a file.")
        XCTAssertGreaterThan(
            dropRejectedHost.measuredFittingSize.height,
            readyWithoutDropHost.measuredFittingSize.height + 28.0
        )
    }

    func testLowSpaceWarningSwitchesFromBlockingToOverrideHIG() {
        let viewModel = configureLowSpaceViewModel(overrideAccepted: false)
        let hosted = hostMainWindow(viewModel)

        LauncherHIGTestHarness.assertNoHorizontalOverflow(hosted, maxWidth: LauncherWindowMetrics.idealWidth, context: "Low space (blocked)")
        LauncherHIGTestHarness.assertEllipsisConvention(titles: ["Import Anyway", "Import"], context: "Low space (blocked)")
        XCTAssertTrue(viewModel.isDestinationSpaceBlocking)
        XCTAssertFalse(viewModel.isImportReady)
        XCTAssertEqual(viewModel.destinationSpaceWarningTone, .error)

        viewModel.acceptDestinationSpaceOverride()
        hosted.relayout()

        LauncherHIGTestHarness.assertNoHorizontalOverflow(hosted, maxWidth: LauncherWindowMetrics.idealWidth, context: "Low space (overridden)")
        XCTAssertFalse(viewModel.isDestinationSpaceBlocking)
        XCTAssertTrue(viewModel.isImportReady)
        XCTAssertEqual(viewModel.destinationSpaceWarningTone, .attention)
    }

    func testCompleteWithWarningsShortFitsNaturallyAndLongCapsScrollHeight() {
        let twoVM = configureCompleteWithWarningsViewModel(warningCount: 2, showActivityGraph: false)
        let twoHost = hostMainWindow(twoVM)
        LauncherHIGTestHarness.assertNoHorizontalOverflow(twoHost, maxWidth: LauncherWindowMetrics.idealWidth, context: "Complete with warnings (2)")
        XCTAssertEqual(twoHost.window.subtitle, "Import Completed With Warnings")

        let tenVM = configureCompleteWithWarningsViewModel(warningCount: 10, showActivityGraph: false)
        let tenHost = hostMainWindow(tenVM)
        LauncherHIGTestHarness.assertNoHorizontalOverflow(tenHost, maxWidth: LauncherWindowMetrics.idealWidth, context: "Complete with warnings (10)")

        let twentyVM = configureCompleteWithWarningsViewModel(warningCount: 20, showActivityGraph: false)
        let twentyHost = hostMainWindow(twentyVM)
        LauncherHIGTestHarness.assertNoHorizontalOverflow(twentyHost, maxWidth: LauncherWindowMetrics.idealWidth, context: "Complete with warnings (20)")

        XCTAssertGreaterThan(tenHost.measuredFittingSize.height, twoHost.measuredFittingSize.height)
        XCTAssertEqual(twentyHost.measuredFittingSize.height, tenHost.measuredFittingSize.height, accuracy: 2.0)
    }

    func testStoppedAndFailedWrapLongMessagesOmitMissingEvidenceAndKeepSingleRowFooter() {
        let stoppedVM = configureStoppedViewModel()
        let stoppedHost = hostMainWindow(stoppedVM)

        let stoppedEvidence = LauncherContentView.failureEvidenceActions(for: stoppedVM)
        let stoppedSecondary = LauncherContentView.failureSecondaryActions(for: stoppedVM)
        let stoppedPrimary = LauncherContentView.failurePrimaryAction(for: stoppedVM)

        LauncherHIGTestHarness.assertNoHorizontalOverflow(stoppedHost, maxWidth: LauncherWindowMetrics.idealWidth, context: "Stopped")
        XCTAssertEqual(stoppedHost.window.subtitle, "Import Stopped")
        XCTAssertEqual(stoppedEvidence.map(\.title), ["Show Staging", "Show Receipt"])
        XCTAssertEqual(stoppedSecondary.map(\.title), ["Show Destination", "Import Another Card"])
        XCTAssertEqual(stoppedPrimary.title, "Back to Setup")
        LauncherHIGTestHarness.assertResultActionBarSingleRow(
            secondaryActions: stoppedSecondary,
            primaryAction: stoppedPrimary,
            context: "Stopped"
        )
        LauncherHIGTestHarness.assertEllipsisConvention(
            titles: ["Show Staging", "Show Receipt", "Show Destination", "Import Another Card", "Back to Setup"],
            context: "Stopped"
        )

        let noEvidenceVM = configureFailedViewModel(
            reason: "No space left on device.",
            includeEvidence: false,
            showActivityGraph: false
        )
        let noEvidenceHost = hostMainWindow(noEvidenceVM)

        let noEvidenceSecondary = LauncherContentView.failureSecondaryActions(for: noEvidenceVM)
        let noEvidencePrimary = LauncherContentView.failurePrimaryAction(for: noEvidenceVM)

        LauncherHIGTestHarness.assertNoHorizontalOverflow(noEvidenceHost, maxWidth: LauncherWindowMetrics.idealWidth, context: "Failed (no evidence)")
        XCTAssertTrue(LauncherContentView.failureEvidenceActions(for: noEvidenceVM).isEmpty)
        XCTAssertEqual(noEvidenceSecondary.map(\.title), ["Show Destination", "Import Another Card"])
        XCTAssertEqual(noEvidencePrimary.title, "Back to Setup")
        LauncherHIGTestHarness.assertResultActionBarSingleRow(
            secondaryActions: noEvidenceSecondary,
            primaryAction: noEvidencePrimary,
            context: "Failed (no evidence)"
        )

        let withEvidenceVM = configureFailedViewModel(
            reason: "No space left on device.",
            includeEvidence: true,
            showActivityGraph: false
        )
        withEvidenceVM.stagingPath = fixtures.stagingURL.path
        let withEvidenceHost = hostMainWindow(withEvidenceVM)

        XCTAssertEqual(LauncherContentView.failureEvidenceActions(for: withEvidenceVM).map(\.title), ["Show Staging", "Show Receipt"])
        XCTAssertGreaterThan(
            withEvidenceHost.measuredFittingSize.height,
            noEvidenceHost.measuredFittingSize.height + 24.0
        )

        let longReason = "Transfer stopped because destination volume could not flush staged media blocks while verifying checksums across DCIM/100SONY/DSC00412.ARW, DCIM/100SONY/DSC00413.ARW, and accompanying XMP sidecars."
        let longFailedVM = configureFailedViewModel(
            reason: longReason,
            includeEvidence: false,
            showActivityGraph: false
        )
        let longFailedHost = hostMainWindow(longFailedVM)

        LauncherHIGTestHarness.assertNoHorizontalOverflow(longFailedHost, maxWidth: LauncherWindowMetrics.idealWidth, context: "Failed (long message)")
        XCTAssertGreaterThan(
            longFailedHost.measuredFittingSize.height,
            noEvidenceHost.measuredFittingSize.height + 24.0
        )
    }

    func testRenderMainWindowHIGSnapshotsIfRequested() throws {
        try XCTSkipUnless(
            LauncherHIGTestHarness.shouldRenderSnapshots,
            "Set FYLURO_RENDER_HIG_SCREENSHOTS=1 to render Dark Mode HIG snapshots."
        )

        let scenarios: [(String, () -> LauncherViewModel)] = [
            ("main-01-setup-empty-source", { self.configureEmptySourceViewModel() }),
            ("main-02-setup-ready", { self.configureSetupReadyViewModel(cameraCount: 3, sidecarCount: 3) }),
            ("main-03-setup-ready-film-mode", {
                let vm = self.configureSetupReadyViewModel(cameraCount: 2, sidecarCount: 1)
                vm.filmModeState = .enabled(
                    FilmModeOverride(
                        year: 2026,
                        month: 10,
                        camera: "Pentax K1000",
                        filmStock: "Kodak Portra 400",
                        iso: 400,
                        creator: nil,
                        copyright: nil
                    )
                )
                return vm
            }),
            ("main-04-setup-empty-media", { self.configureEmptyMediaViewModel() }),
            ("main-05-setup-unreadable-source", { self.configureUnreadableSourceViewModel() }),
            ("main-06-setup-route-error", { self.configureRouteErrorViewModel() }),
            ("main-07-setup-drop-rejected", { self.configureDropRejectedViewModel() }),
            ("main-08-setup-low-space-blocked", { self.configureLowSpaceViewModel(overrideAccepted: false) }),
            ("main-09-setup-low-space-override", { self.configureLowSpaceViewModel(overrideAccepted: true) }),
            ("main-10-importing-copy-activity", { self.configureImportingViewModel(showActivityGraph: true) }),
            ("main-11-complete-fresh", { self.configureCompleteFreshViewModel() }),
            ("main-12-complete-idempotent", { self.configureCompleteIdempotentViewModel() }),
            ("main-13-complete-warnings", { self.configureCompleteWithWarningsViewModel(warningCount: 3, showActivityGraph: false) }),
            ("main-14-stopped", { self.configureStoppedViewModel() }),
            ("main-15-failed", {
                self.configureFailedViewModel(
                    reason: "Destination has insufficient free space: need 5.5 MB (5.2 MB of media + 262 KB safety margin), but only 1.8 MB available.",
                    includeEvidence: true,
                    showActivityGraph: false
                )
            }),
        ]

        for (name, buildViewModel) in scenarios {
            let hosted = hostMainWindow(buildViewModel())
            try LauncherHIGTestHarness.writeDarkModeSnapshot(named: name, hosted: hosted)
        }
    }

    // MARK: - Scenario Builders

    private func configureEmptySourceViewModel() -> LauncherViewModel {
        let viewModel = LauncherHIGTestHarness.makeIsolatedViewModel()
        viewModel.sourcePath = ""
        viewModel.destinationPath = fixtures.destinationURL.path
        LauncherHIGTestHarness.cancelBackgroundTasks(on: viewModel)
        viewModel.runState = .idle
        viewModel.sourceScanState = .idle
        viewModel.destinationSpaceState = .sufficient(availableBytes: 42_000_000_000)
        viewModel.statusMessage = "Choose a readable source to begin."
        return viewModel
    }

    private func configureSetupReadyViewModel(cameraCount: Int, sidecarCount: Int = 2) -> LauncherViewModel {
        let viewModel = LauncherHIGTestHarness.makeIsolatedViewModel()
        viewModel.sourcePath = fixtures.sourceURL.path
        viewModel.destinationPath = fixtures.destinationURL.path
        LauncherHIGTestHarness.cancelBackgroundTasks(on: viewModel)
        viewModel.runState = .ready
        viewModel.statusMessage = "Import ready"
        viewModel.destinationSpaceState = .sufficient(availableBytes: 42_000_000_000)
        viewModel.sourceScanState = .ready(
            LauncherHIGTestHarness.makeSampleSummary(sidecarCount: sidecarCount, cameraCount: cameraCount)
        )
        return viewModel
    }

    private func configureEmptyMediaViewModel() -> LauncherViewModel {
        let viewModel = LauncherHIGTestHarness.makeIsolatedViewModel()
        viewModel.sourcePath = fixtures.sourceURL.path
        viewModel.destinationPath = fixtures.destinationURL.path
        LauncherHIGTestHarness.cancelBackgroundTasks(on: viewModel)
        viewModel.runState = .ready
        viewModel.statusMessage = "Import ready"
        viewModel.destinationSpaceState = .sufficient(availableBytes: 42_000_000_000)
        viewModel.sourceScanState = .ready(
            LauncherSourceScopeSummary(itemCount: 0, photoCount: 0, videoCount: 0, totalBytes: 0)
        )
        return viewModel
    }

    private func configureUnreadableSourceViewModel() -> LauncherViewModel {
        let viewModel = LauncherHIGTestHarness.makeIsolatedViewModel()
        viewModel.sourcePath = fixtures.rootURL.appendingPathComponent("UNREADABLE_CARD").path
        viewModel.destinationPath = fixtures.destinationURL.path
        LauncherHIGTestHarness.cancelBackgroundTasks(on: viewModel)
        viewModel.runState = .idle
        viewModel.sourceScanState = .failed("Source must be a readable folder.")
        viewModel.destinationSpaceState = .sufficient(availableBytes: 42_000_000_000)
        viewModel.statusMessage = "Source must be a readable folder."
        return viewModel
    }

    private func configureRouteErrorViewModel() -> LauncherViewModel {
        let viewModel = LauncherHIGTestHarness.makeIsolatedViewModel()
        viewModel.sourcePath = fixtures.sourceURL.path
        viewModel.destinationPath = fixtures.rootURL.appendingPathComponent("READONLY_DEST").path
        LauncherHIGTestHarness.cancelBackgroundTasks(on: viewModel)
        viewModel.runState = .idle
        viewModel.sourceScanState = .ready(LauncherHIGTestHarness.makeSampleSummary(cameraCount: 2))
        viewModel.destinationSpaceState = .unchecked
        viewModel.statusMessage = "Destination must be a writable folder."
        return viewModel
    }

    private func configureDropRejectedViewModel() -> LauncherViewModel {
        let viewModel = configureSetupReadyViewModel(cameraCount: 2)
        viewModel.dropRejectedMessage = "Drop a folder, not a file."
        return viewModel
    }

    private func configureLowSpaceViewModel(overrideAccepted: Bool) -> LauncherViewModel {
        let viewModel = configureSetupReadyViewModel(cameraCount: 2, sidecarCount: 0)
        viewModel.destinationSpaceState = .insufficient(
            DestinationSpaceChecker.InsufficientSpace(availableBytes: 1_900_000, requiredBytes: 5_500_000),
            overrideAccepted: overrideAccepted
        )
        return viewModel
    }

    private func configureImportingViewModel(showActivityGraph: Bool) -> LauncherViewModel {
        let viewModel = LauncherHIGTestHarness.makeIsolatedViewModel()
        viewModel.sourcePath = fixtures.sourceURL.path
        viewModel.destinationPath = fixtures.destinationURL.path
        LauncherHIGTestHarness.cancelBackgroundTasks(on: viewModel)
        viewModel.runState = .running(stopRequested: false)
        viewModel.latestCorePhase = .copy
        viewModel.currentPhase = .copy
        viewModel.scannedCandidateCount = 48
        viewModel.copiedCount = 18
        viewModel.bytesToCopy = 1_200_000_000
        viewModel.runStartedAt = Date().addingTimeInterval(-8)
        viewModel.currentFilePath = fixtures.sourceURL.appendingPathComponent("DCIM/100SONY/DSC00018.ARW").path
        LauncherHIGTestHarness.seedThroughputTelemetry(on: viewModel, finalized: false)
        viewModel.showThroughputGraph = showActivityGraph
        return viewModel
    }

    private func configureCompleteFreshViewModel() -> LauncherViewModel {
        let viewModel = LauncherHIGTestHarness.makeIsolatedViewModel()
        viewModel.sourcePath = fixtures.sourceURL.path
        viewModel.destinationPath = fixtures.destinationURL.path
        LauncherHIGTestHarness.cancelBackgroundTasks(on: viewModel)
        viewModel.runState = .succeeded(idempotentRerun: false)
        viewModel.createdDirectories = [fixtures.finalMediaURL.path]
        viewModel.receiptPath = fixtures.receiptURL.path
        viewModel.finalizedCommittedCount = 24
        viewModel.finalizedDuplicateNotCopiedCount = 2
        viewModel.finalizedPhotoCount = 20
        viewModel.finalizedVideoCount = 3
        viewModel.finalizedAudioCount = 1
        viewModel.finalizedSidecarCount = 3
        viewModel.finalizedConflictsRenamedCount = 1
        viewModel.scannedTotalBytes = 1_420_000_000
        viewModel.finalizedTotalDurationMs = 12_200
        viewModel.finalizedFilmModeExifSkippedCount = 2
        viewModel.filmModeState = .enabled(
            FilmModeOverride(
                year: 2026,
                month: 10,
                camera: "Pentax K1000",
                filmStock: "Portra 400",
                iso: 400,
                creator: nil,
                copyright: nil
            )
        )
        viewModel.lastPreviewSummary = LauncherHIGTestHarness.makeSampleSummary(cameraCount: 3)
        LauncherHIGTestHarness.seedThroughputTelemetry(on: viewModel, finalized: true)
        viewModel.showThroughputGraph = true
        return viewModel
    }

    private func configureCompleteIdempotentViewModel() -> LauncherViewModel {
        let viewModel = LauncherHIGTestHarness.makeIsolatedViewModel()
        viewModel.sourcePath = fixtures.sourceURL.path
        viewModel.destinationPath = fixtures.destinationURL.path
        LauncherHIGTestHarness.cancelBackgroundTasks(on: viewModel)
        viewModel.runState = .succeeded(idempotentRerun: true)
        viewModel.createdDirectories = []
        viewModel.receiptPath = fixtures.receiptURL.path
        viewModel.finalizedCommittedCount = 0
        viewModel.finalizedDuplicateNotCopiedCount = 12
        viewModel.scannedTotalBytes = 640_000_000
        viewModel.finalizedTotalDurationMs = 1_200
        viewModel.showThroughputGraph = false
        return viewModel
    }

    private func configureCompleteWithWarningsViewModel(warningCount: Int, showActivityGraph: Bool) -> LauncherViewModel {
        let viewModel = LauncherHIGTestHarness.makeIsolatedViewModel()
        viewModel.sourcePath = fixtures.sourceURL.path
        viewModel.destinationPath = fixtures.destinationURL.path
        LauncherHIGTestHarness.cancelBackgroundTasks(on: viewModel)
        viewModel.runState = .succeeded(idempotentRerun: false)
        viewModel.createdDirectories = [fixtures.finalMediaURL.path]
        viewModel.receiptPath = fixtures.receiptURL.path
        viewModel.finalizedCommittedCount = 8
        viewModel.finalizedDuplicateNotCopiedCount = 1
        viewModel.finalizedPhotoCount = 4
        viewModel.finalizedVideoCount = 4
        viewModel.scannedTotalBytes = 480_000_000
        viewModel.finalizedTotalDurationMs = 4_000
        viewModel.lastPreviewSummary = LauncherHIGTestHarness.makeSampleSummary(cameraCount: 2)
        let paths = (1...warningCount).map {
            fixtures.sourceURL.appendingPathComponent(String(format: "DCIM/IMG_%04d.DNG", $0)).path
        }
        viewModel.receiptErrors = [
            ReceiptErrorItem(
                eventIndex: 1,
                phase: .scan,
                message: "File is not readable",
                paths: paths
            ),
        ]
        viewModel.showThroughputGraph = showActivityGraph
        return viewModel
    }

    private func configureStoppedViewModel() -> LauncherViewModel {
        let viewModel = LauncherHIGTestHarness.makeIsolatedViewModel()
        viewModel.sourcePath = fixtures.sourceURL.path
        viewModel.destinationPath = fixtures.destinationURL.path
        LauncherHIGTestHarness.cancelBackgroundTasks(on: viewModel)
        viewModel.runState = .failed(stoppedByUser: true)
        viewModel.finalizedCommittedCount = 0
        viewModel.receiptPath = fixtures.receiptURL.path
        viewModel.stagingPath = fixtures.stagingURL.path
        LauncherHIGTestHarness.seedThroughputTelemetry(on: viewModel, finalized: true)
        viewModel.showThroughputGraph = true
        return viewModel
    }

    private func configureFailedViewModel(
        reason: String,
        includeEvidence: Bool,
        showActivityGraph: Bool
    ) -> LauncherViewModel {
        let viewModel = LauncherHIGTestHarness.makeIsolatedViewModel()
        viewModel.sourcePath = fixtures.sourceURL.path
        viewModel.destinationPath = fixtures.destinationURL.path
        LauncherHIGTestHarness.cancelBackgroundTasks(on: viewModel)
        viewModel.runState = .failed(stoppedByUser: false)
        viewModel.failureReason = reason
        viewModel.finalizedCommittedCount = 0
        viewModel.receiptPath = includeEvidence ? fixtures.receiptURL.path : ""
        viewModel.stagingPath = ""
        viewModel.showThroughputGraph = showActivityGraph
        return viewModel
    }
}
