import AppKit
import Foundation
import FyluroCore
import FyluroEngine
import SwiftUI
import XCTest
@testable import fyluroLauncher

@MainActor
final class LauncherHIGSecondaryWindowsTests: XCTestCase {
    private var fixtures: HIGTempFixtures!
    private var hostedViews: [HostedHIGView] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        fixtures = try HIGTempFixtures()
    }

    override func tearDownWithError() throws {
        for hosted in hostedViews {
            hosted.close()
        }
        hostedViews.removeAll()
        fixtures?.cleanup()
        fixtures = nil
        try super.tearDownWithError()
    }

    private func hostPane<Content: View>(
        width: CGFloat,
        fixedHeight: CGFloat? = nil,
        title: String = AppBrand.name,
        @ViewBuilder content: () -> Content
    ) -> HostedHIGView {
        let hosted = HostedHIGView(width: width, fixedHeight: fixedHeight, title: title, content: content)
        hostedViews.append(hosted)
        return hosted
    }

    func testFilmModeSheetFitsMetricsAndFollowsMacOSButtonOrder() {
        let viewModel = LauncherHIGTestHarness.makeIsolatedViewModel()
        let newHost = hostPane(
            width: LauncherWindowMetrics.filmModeSheetWidth,
            fixedHeight: LauncherWindowMetrics.filmModeSheetHeight,
            title: "Film Mode"
        ) {
            LauncherFilmModeSheet(viewModel: viewModel, editing: nil)
        }

        LauncherHIGTestHarness.assertNoHorizontalOverflow(newHost, maxWidth: LauncherWindowMetrics.filmModeSheetWidth, context: "Film Mode sheet (new)")
        XCTAssertLessThanOrEqual(newHost.measuredFittingSize.height, LauncherWindowMetrics.filmModeSheetHeight + 1.0)
        LauncherHIGTestHarness.assertEllipsisConvention(titles: ["Cancel", "Apply"], context: "Film Mode sheet (new)")

        let newDraft = FilmModeDraft(remembering: nil)
        XCTAssertFalse(newDraft.canApply)
        XCTAssertNotNil(newDraft.missingRequirementsMessage)

        let existingOverride = FilmModeOverride(
            year: 1998,
            month: 6,
            camera: "Pentax K1000",
            filmStock: "Kodak Gold 200",
            iso: 200,
            creator: "Jane Doe",
            copyright: nil
        )
        let editHost = hostPane(
            width: LauncherWindowMetrics.filmModeSheetWidth,
            fixedHeight: LauncherWindowMetrics.filmModeSheetHeight,
            title: "Film Mode"
        ) {
            LauncherFilmModeSheet(viewModel: viewModel, editing: existingOverride)
        }

        LauncherHIGTestHarness.assertNoHorizontalOverflow(editHost, maxWidth: LauncherWindowMetrics.filmModeSheetWidth, context: "Film Mode sheet (edit)")
        XCTAssertLessThanOrEqual(editHost.measuredFittingSize.height, LauncherWindowMetrics.filmModeSheetHeight + 1.0)

        let editDraft = FilmModeDraft(editing: existingOverride)
        XCTAssertTrue(editDraft.canApply)
        XCTAssertNil(editDraft.missingRequirementsMessage)
    }

    func testSettingsLibraryPaneFitsWidthGrowsWithWarningsAndAlignsFooter() {
        let store = LauncherPathSchemeSettingsStore(
            pathSchemeRemembering: StubLauncherPathSchemeRemembering(initialConfiguration: .default)
        )
        let cleanHost = hostPane(width: LauncherSettingsWindowMetrics.width, title: "Library") {
            LauncherSettingsView(pathSchemeSettingsStore: store)
        }

        LauncherHIGTestHarness.assertNoHorizontalOverflow(cleanHost, maxWidth: LauncherSettingsWindowMetrics.width, context: "Settings Library (clean)")
        LauncherHIGTestHarness.assertEllipsisConvention(titles: ["Reset to Default", "Apply"], context: "Settings Library (clean)")
        XCTAssertFalse(store.hasPendingChanges)
        XCTAssertTrue(store.pendingWarningMessages.isEmpty)

        let cleanHeight = cleanHost.measuredFittingSize.height

        store.draftConfiguration.chronologicalLayout = .yearOnly
        store.draftConfiguration.includeCameraFolder = false
        let warningHost = hostPane(width: LauncherSettingsWindowMetrics.width, title: "Library") {
            LauncherSettingsView(pathSchemeSettingsStore: store)
        }

        LauncherHIGTestHarness.assertNoHorizontalOverflow(warningHost, maxWidth: LauncherSettingsWindowMetrics.width, context: "Settings Library (warnings)")
        XCTAssertTrue(store.hasPendingChanges)
        XCTAssertFalse(store.pendingWarningMessages.isEmpty)
        XCTAssertGreaterThan(warningHost.measuredFittingSize.height, cleanHeight + 50.0)
    }

    func testSettingsCameraLabelsPaneFitsWidthAcrossStatesAndCapsHeight() {
        let disabledStore = makeDisabledCameraCatalogStore()
        let disabledHost = hostPane(width: LauncherSettingsWindowMetrics.width, title: "Camera Labels") {
            LauncherCameraLabelsSettingsView(store: disabledStore)
        }
        LauncherHIGTestHarness.assertNoHorizontalOverflow(disabledHost, maxWidth: LauncherSettingsWindowMetrics.width, context: "Camera Labels (disabled)")
        XCTAssertLessThanOrEqual(disabledHost.measuredFittingSize.height, 235.0)

        let malformedStore = LauncherCameraCatalogStore(
            remembering: StubCameraCatalogRemembering(.malformed("bad json")),
            preference: StubCameraLabelsPreference(isEnabled: true)
        )
        malformedStore.updateDetectedCameras(from: [
            LauncherSourceCameraSummary(label: "ilce-7m4", fileCount: 12, rawModelCode: "ILCE-7M4"),
            LauncherSourceCameraSummary(label: "ac006", fileCount: 5, rawModelCode: "AC006"),
        ])
        let malformedHost = hostPane(width: LauncherSettingsWindowMetrics.width, title: "Camera Labels") {
            LauncherCameraLabelsSettingsView(store: malformedStore)
        }
        LauncherHIGTestHarness.assertNoHorizontalOverflow(malformedHost, maxWidth: LauncherSettingsWindowMetrics.width, context: "Camera Labels (malformed)")
        XCTAssertGreaterThan(malformedHost.measuredFittingSize.height, disabledHost.measuredFittingSize.height)

        let enabledStore = makeEnabledCameraCatalogStoreWithDetectedAndSaved()
        let enabledHost = hostPane(width: LauncherSettingsWindowMetrics.width, title: "Camera Labels") {
            LauncherCameraLabelsSettingsView(store: enabledStore)
        }
        LauncherHIGTestHarness.assertNoHorizontalOverflow(enabledHost, maxWidth: LauncherSettingsWindowMetrics.width, context: "Camera Labels (enabled)")
        XCTAssertGreaterThan(enabledHost.measuredFittingSize.height, disabledHost.measuredFittingSize.height)

        let manyEntries = Dictionary(uniqueKeysWithValues: (1...20).map { index in
            (String(format: "CAM-%02d", index), String(format: "Camera %02d", index))
        })
        let cappedStore = LauncherCameraCatalogStore(
            remembering: StubCameraCatalogRemembering(.loaded(manyEntries)),
            preference: StubCameraLabelsPreference(isEnabled: true)
        )
        let cappedHost = hostPane(width: LauncherSettingsWindowMetrics.width, title: "Camera Labels") {
            LauncherCameraLabelsSettingsView(store: cappedStore)
        }
        LauncherHIGTestHarness.assertNoHorizontalOverflow(cappedHost, maxWidth: LauncherSettingsWindowMetrics.width, context: "Camera Labels (capped)")
        XCTAssertLessThanOrEqual(cappedHost.measuredFittingSize.height, LauncherSettingsWindowMetrics.maxPaneHeight + 1.0)
    }

    func testRenderSecondaryWindowHIGSnapshotsIfRequested() throws {
        try XCTSkipUnless(
            LauncherHIGTestHarness.shouldRenderSnapshots,
            "Set FYLURO_RENDER_HIG_SCREENSHOTS=1 to render Dark Mode HIG snapshots."
        )

        let vm = LauncherHIGTestHarness.makeIsolatedViewModel()
        let filmOverride = FilmModeOverride(
            year: 1998,
            month: 6,
            camera: "Pentax K1000",
            filmStock: "Kodak Gold 200",
            iso: 200,
            creator: "Jane Doe",
            copyright: nil
        )
        let filmHost = hostPane(
            width: LauncherWindowMetrics.filmModeSheetWidth,
            fixedHeight: LauncherWindowMetrics.filmModeSheetHeight,
            title: "Film Mode"
        ) {
            LauncherFilmModeSheet(viewModel: vm, editing: filmOverride)
        }
        try LauncherHIGTestHarness.writeDarkModeSnapshot(named: "sheet-01-film-mode", hosted: filmHost)

        let cleanLibraryStore = LauncherPathSchemeSettingsStore(
            pathSchemeRemembering: StubLauncherPathSchemeRemembering(initialConfiguration: .default)
        )
        let libraryHost = hostPane(width: LauncherSettingsWindowMetrics.width, title: "Library") {
            LauncherSettingsView(pathSchemeSettingsStore: cleanLibraryStore)
        }
        try LauncherHIGTestHarness.writeDarkModeSnapshot(named: "settings-01-library", hosted: libraryHost)

        let warningLibraryStore = LauncherPathSchemeSettingsStore(
            pathSchemeRemembering: StubLauncherPathSchemeRemembering(initialConfiguration: .default)
        )
        warningLibraryStore.draftConfiguration.chronologicalLayout = .yearOnly
        warningLibraryStore.draftConfiguration.includeCameraFolder = false
        let warningLibraryHost = hostPane(width: LauncherSettingsWindowMetrics.width, title: "Library") {
            LauncherSettingsView(pathSchemeSettingsStore: warningLibraryStore)
        }
        try LauncherHIGTestHarness.writeDarkModeSnapshot(named: "settings-02-library-warning", hosted: warningLibraryHost)

        let disabledLabelsHost = hostPane(width: LauncherSettingsWindowMetrics.width, title: "Camera Labels") {
            LauncherCameraLabelsSettingsView(store: makeDisabledCameraCatalogStore())
        }
        try LauncherHIGTestHarness.writeDarkModeSnapshot(named: "settings-03-camera-labels-disabled", hosted: disabledLabelsHost)

        let enabledLabelsHost = hostPane(width: LauncherSettingsWindowMetrics.width, title: "Camera Labels") {
            LauncherCameraLabelsSettingsView(store: makeEnabledCameraCatalogStoreWithDetectedAndSaved())
        }
        try LauncherHIGTestHarness.writeDarkModeSnapshot(named: "settings-04-camera-labels-enabled", hosted: enabledLabelsHost)
    }

    // MARK: - Store Builders

    private func makeDisabledCameraCatalogStore() -> LauncherCameraCatalogStore {
        LauncherCameraCatalogStore(
            remembering: StubCameraCatalogRemembering(.missing),
            preference: StubCameraLabelsPreference(isEnabled: false)
        )
    }

    private func makeEnabledCameraCatalogStoreWithDetectedAndSaved() -> LauncherCameraCatalogStore {
        let store = LauncherCameraCatalogStore(
            remembering: StubCameraCatalogRemembering(.loaded([
                "AC006": "OsmoAction6",
                "ILCE-7M4": "Sony A7 IV",
            ])),
            preference: StubCameraLabelsPreference(isEnabled: true)
        )
        store.updateDetectedCameras(from: [
            LauncherSourceCameraSummary(label: "ilce-7m4", fileCount: 14, rawModelCode: "ILCE-7M4"),
            LauncherSourceCameraSummary(label: "dc-g9", fileCount: 6, rawModelCode: "DC-G9"),
            LauncherSourceCameraSummary(label: "x100vi", fileCount: 9, rawModelCode: "X100VI"),
        ])
        return store
    }
}
