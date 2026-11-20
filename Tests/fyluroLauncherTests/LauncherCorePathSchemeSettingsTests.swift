import XCTest
@testable import fyluroLauncher
@testable import FyluroCore

extension LauncherCoreTests {
    func testPathSchemeMemoryRoundTripsAppliedConfiguration() {
        let suiteName = "fyluro-launcher-path-scheme-\(UUID().uuidString)"
        guard let userDefaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Expected dedicated UserDefaults suite")
            return
        }
        defer {
            userDefaults.removePersistentDomain(forName: suiteName)
        }

        let memory = LauncherPathSchemeMemory(
            userDefaults: userDefaults,
            chronologicalKey: "chronological",
            includeCameraKey: "includeCamera",
            splitPhotoCompressionKey: "splitPhotoCompression"
        )

        XCTAssertEqual(memory.loadAppliedPathScheme(), .default)

        let updated = LauncherPathSchemeConfiguration(
            chronologicalLayout: .yearMonthNested,
            includeCameraFolder: false,
            splitPhotoCompression: true
        )
        memory.saveAppliedPathScheme(updated)

        XCTAssertEqual(memory.loadAppliedPathScheme(), updated)
    }

    @MainActor
    func testPathSchemeSettingsStoreStagesUntilApply() {
        let remembering = StubLauncherPathSchemeRemembering(initialConfiguration: .default)
        let store = LauncherPathSchemeSettingsStore(pathSchemeRemembering: remembering)

        store.draftConfiguration = LauncherPathSchemeConfiguration(
            chronologicalLayout: .yearMonthNested,
            includeCameraFolder: false,
            splitPhotoCompression: true
        )

        XCTAssertNotEqual(store.appliedConfiguration, store.draftConfiguration)
        XCTAssertEqual(remembering.savedConfigurations.count, 0)

        store.applyDraft()

        XCTAssertEqual(store.appliedConfiguration, store.draftConfiguration)
        XCTAssertEqual(remembering.savedConfigurations.count, 1)
    }

    @MainActor
    func testPathSchemeSettingsStoreResetToDefaultChangesDraftOnly() {
        let initial = LauncherPathSchemeConfiguration(
            chronologicalLayout: .yearMonthNested,
            includeCameraFolder: false,
            splitPhotoCompression: true
        )
        let remembering = StubLauncherPathSchemeRemembering(initialConfiguration: initial)
        let store = LauncherPathSchemeSettingsStore(pathSchemeRemembering: remembering)

        store.resetDraftToDefault()

        XCTAssertEqual(store.draftConfiguration, .default)
        XCTAssertEqual(store.appliedConfiguration, initial)
        XCTAssertEqual(remembering.savedConfigurations.count, 0)
    }

    @MainActor
    func testPathSchemeSettingsStorePreviewReflectsDraftConfiguration() {
        let remembering = StubLauncherPathSchemeRemembering(initialConfiguration: .default)
        let store = LauncherPathSchemeSettingsStore(pathSchemeRemembering: remembering)

        store.draftConfiguration = LauncherPathSchemeConfiguration(
            chronologicalLayout: .yearMonthNested,
            includeCameraFolder: false,
            splitPhotoCompression: true
        )

        XCTAssertEqual(
            store.draftPhotoPreviewPath,
            "<DEST>/2026/03/Photos/RAW/DSC01234.ARW"
        )
        XCTAssertEqual(
            store.draftVideoPreviewPath,
            "<DEST>/2026/03/Videos/C0001.MP4"
        )

        store.draftConfiguration = LauncherPathSchemeConfiguration(
            chronologicalLayout: .yearOnly,
            includeCameraFolder: true,
            splitPhotoCompression: false
        )

        XCTAssertEqual(
            store.draftPhotoPreviewPath,
            "<DEST>/2026/sony-a7iv/Photos/DSC01234.ARW"
        )
        XCTAssertEqual(
            store.draftVideoPreviewPath,
            "<DEST>/2026/sony-a7iv/Videos/C0001.MP4"
        )
        XCTAssertEqual(
            store.draftAudioPreviewPath,
            "<DEST>/2026/audio/iphone recording.m4a"
        )
    }

    @MainActor
    func testPathSchemeSettingsStorePendingWarningsEmptyWhenDraftMatchesApplied() {
        let remembering = StubLauncherPathSchemeRemembering(initialConfiguration: .default)
        let store = LauncherPathSchemeSettingsStore(pathSchemeRemembering: remembering)

        XCTAssertFalse(store.hasPendingChanges)
        XCTAssertEqual(store.pendingWarningMessages, [])
        XCTAssertFalse(store.shouldShowPendingWarnings)
    }

    @MainActor
    func testPathSchemeSettingsStorePendingWarningsIncludeChronologicalChangeWarning() {
        let remembering = StubLauncherPathSchemeRemembering(initialConfiguration: .default)
        let store = LauncherPathSchemeSettingsStore(pathSchemeRemembering: remembering)
        var updated = store.draftConfiguration
        updated.chronologicalLayout = .yearMonthNested
        store.draftConfiguration = updated

        XCTAssertEqual(store.pendingWarningMessages, [
            "Frequent path scheme changes can create mixed destination structures over time.",
        ])
        XCTAssertTrue(store.shouldShowPendingWarnings)
    }

    @MainActor
    func testPathSchemeSettingsStorePendingWarningsIncludeCameraGroupingWarningWhenDisabled() {
        let remembering = StubLauncherPathSchemeRemembering(initialConfiguration: .default)
        let store = LauncherPathSchemeSettingsStore(pathSchemeRemembering: remembering)
        var updated = store.draftConfiguration
        updated.includeCameraFolder = false
        store.draftConfiguration = updated

        XCTAssertEqual(store.pendingWarningMessages, [
            "Disabling camera grouping can increase filename collision suffixes (-1, -2, ...).",
        ])
        XCTAssertTrue(store.shouldShowPendingWarnings)
    }

    @MainActor
    func testPathSchemeSettingsStorePendingWarningsStayScopedToChangedSettings() {
        let remembering = StubLauncherPathSchemeRemembering(initialConfiguration: .default)
        let store = LauncherPathSchemeSettingsStore(pathSchemeRemembering: remembering)
        var updated = store.draftConfiguration
        updated.splitPhotoCompression = true
        store.draftConfiguration = updated

        XCTAssertTrue(store.hasPendingChanges)
        XCTAssertEqual(store.pendingWarningMessages, [])
        XCTAssertFalse(store.shouldShowPendingWarnings)
    }

    @MainActor
    func testPathSchemeSettingsStorePendingWarningsClearAfterApply() {
        let remembering = StubLauncherPathSchemeRemembering(initialConfiguration: .default)
        let store = LauncherPathSchemeSettingsStore(pathSchemeRemembering: remembering)
        var updated = store.draftConfiguration
        updated.chronologicalLayout = .yearMonthNested
        updated.includeCameraFolder = false
        store.draftConfiguration = updated

        XCTAssertEqual(store.pendingWarningMessages, [
            "Frequent path scheme changes can create mixed destination structures over time.",
            "Disabling camera grouping can increase filename collision suffixes (-1, -2, ...).",
        ])
        XCTAssertTrue(store.shouldShowPendingWarnings)

        store.applyDraft()

        XCTAssertEqual(store.pendingWarningMessages, [])
        XCTAssertFalse(store.shouldShowPendingWarnings)
    }

    func testConfigurationMapsToCorePathScheme() {
        let configuration = LauncherPathSchemeConfiguration(
            chronologicalLayout: .yearMonthNested,
            includeCameraFolder: false,
            splitPhotoCompression: true
        )

        XCTAssertEqual(
            configuration.corePathScheme,
            ImportPathScheme(
                chronologicalLayout: .yearMonthNested,
                includeCameraFolder: false,
                splitPhotoCompression: true
            )
        )
    }

}
