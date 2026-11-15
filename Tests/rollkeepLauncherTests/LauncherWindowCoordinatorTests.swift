import AppKit
import XCTest
@testable import rollkeepLauncher

@MainActor
final class LauncherWindowCoordinatorTests: XCTestCase {
    private final class StubManagedWindow: LauncherManagedWindow {
        var isAlive = true
        var isMiniaturized = false
        private(set) var deminiaturizeCallCount = 0
        private(set) var bringToFrontCallCount = 0

        func deminiaturize() {
            deminiaturizeCallCount += 1
            isMiniaturized = false
        }

        func bringToFront() {
            bringToFrontCallCount += 1
        }
    }

    func testReopenOpensCleanMainWindowWhenNoMainWindowExists() {
        var openWindowCount = 0
        var activateCount = 0
        let coordinator = LauncherMainWindowCoordinator(activateAppHandler: {
            activateCount += 1
        })
        coordinator.openWindowHandler = {
            openWindowCount += 1
        }

        XCTAssertFalse(coordinator.hasMainWindow)
        let shouldLetAppKitHandle = coordinator.handleReopen()

        XCTAssertFalse(shouldLetAppKitHandle)
        XCTAssertEqual(openWindowCount, 1)
        XCTAssertEqual(activateCount, 1)
    }

    func testReopenBringsExistingMainWindowToFrontWithoutOpeningSecondWindow() {
        var openWindowCount = 0
        var activateCount = 0
        let coordinator = LauncherMainWindowCoordinator(activateAppHandler: {
            activateCount += 1
        })
        coordinator.openWindowHandler = {
            openWindowCount += 1
        }

        let window = StubManagedWindow()
        coordinator.register(window: window, id: ObjectIdentifier(window))
        XCTAssertTrue(coordinator.hasMainWindow)

        let shouldLetAppKitHandle = coordinator.handleReopen()

        XCTAssertFalse(shouldLetAppKitHandle)
        XCTAssertEqual(openWindowCount, 0)
        XCTAssertEqual(window.deminiaturizeCallCount, 0)
        XCTAssertEqual(window.bringToFrontCallCount, 1)
        XCTAssertEqual(activateCount, 1)
    }

    func testReopenDeminiaturizesMinimizedMainWindowWithoutOpeningSecondWindow() {
        var openWindowCount = 0
        let coordinator = LauncherMainWindowCoordinator(activateAppHandler: {})
        coordinator.openWindowHandler = {
            openWindowCount += 1
        }

        let window = StubManagedWindow()
        window.isMiniaturized = true
        coordinator.register(window: window, id: ObjectIdentifier(window))

        _ = coordinator.handleReopen()

        XCTAssertEqual(openWindowCount, 0)
        XCTAssertEqual(window.deminiaturizeCallCount, 1)
        XCTAssertEqual(window.bringToFrontCallCount, 1)
    }

    func testReopenOpensCleanWindowAfterExistingWindowCloses() {
        var openWindowCount = 0
        let coordinator = LauncherMainWindowCoordinator(activateAppHandler: {})
        coordinator.openWindowHandler = {
            openWindowCount += 1
        }

        let window = StubManagedWindow()
        let windowID = ObjectIdentifier(window)
        coordinator.register(window: window, id: windowID)
        XCTAssertTrue(coordinator.hasMainWindow)

        coordinator.unregister(id: windowID)
        XCTAssertFalse(coordinator.hasMainWindow)

        _ = coordinator.handleReopen()
        XCTAssertEqual(openWindowCount, 1)
    }

    func testOpenNewWindowIfNeededPreventsSecondWindowWhileOneIsOpen() {
        var openWindowCount = 0
        let coordinator = LauncherMainWindowCoordinator(activateAppHandler: {})
        coordinator.openWindowHandler = {
            openWindowCount += 1
        }

        let window = StubManagedWindow()
        coordinator.register(window: window, id: ObjectIdentifier(window))

        coordinator.openNewWindowIfNeeded()

        XCTAssertEqual(openWindowCount, 0)
        XCTAssertEqual(window.bringToFrontCallCount, 1)
    }

    func testRepeatedOpenBeforeRegistrationOnlyTriggersOneWindowOpen() {
        var openWindowCount = 0
        let coordinator = LauncherMainWindowCoordinator(activateAppHandler: {})
        coordinator.openWindowHandler = {
            openWindowCount += 1
        }

        coordinator.openNewWindowIfNeeded()
        coordinator.openNewWindowIfNeeded()

        XCTAssertEqual(openWindowCount, 1)
    }

    func testNSWindowRegistrationConfiguresIdentifierTabbingAndCloseObserver() {
        let notificationCenter = NotificationCenter()
        let coordinator = LauncherMainWindowCoordinator(
            notificationCenter: notificationCenter,
            activateAppHandler: {}
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 612),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )

        coordinator.register(nsWindow: window)
        XCTAssertTrue(coordinator.hasMainWindow)
        XCTAssertEqual(window.identifier, LauncherWindowIdentifier.main)
        XCTAssertEqual(window.tabbingMode, .disallowed)

        notificationCenter.post(name: NSWindow.willCloseNotification, object: window)
        XCTAssertFalse(coordinator.hasMainWindow)
    }

    func testAppDelegateReopenOpensMainWindowEvenWhenOtherWindowsAreVisible() {
        var openWindowCount = 0
        let coordinator = LauncherMainWindowCoordinator(activateAppHandler: {})
        coordinator.openWindowHandler = {
            openWindowCount += 1
        }

        let delegate = RollkeepAppDelegate()
        delegate.windowCoordinator = coordinator

        let result = delegate.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: true)
        XCTAssertFalse(result)
        XCTAssertEqual(openWindowCount, 1)
    }
}
