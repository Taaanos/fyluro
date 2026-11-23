import AppKit
import XCTest
@testable import fyluroLauncher

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
        XCTAssertTrue(window.collectionBehavior.contains(.fullScreenNone))
        XCTAssertFalse(window.collectionBehavior.contains(.fullScreenPrimary))

        notificationCenter.post(name: NSWindow.willCloseNotification, object: window)
        XCTAssertFalse(coordinator.hasMainWindow)
    }

    func testAppDelegateReopenOpensMainWindowEvenWhenOtherWindowsAreVisible() {
        var openWindowCount = 0
        let coordinator = LauncherMainWindowCoordinator(activateAppHandler: {})
        coordinator.openWindowHandler = {
            openWindowCount += 1
        }

        let delegate = FyluroAppDelegate()
        delegate.windowCoordinator = coordinator

        let result = delegate.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: true)
        XCTAssertFalse(result)
        XCTAssertEqual(openWindowCount, 1)
    }

    func testWindowObserverViewAppliesAndClearsNSWindowSubtitle() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 612),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let observerView = LauncherMainWindowAccessor.WindowObserverView()
        observerView.updateWindowSubtitle("Importing 12 items…")

        window.contentView?.addSubview(observerView)
        XCTAssertEqual(window.subtitle, "Importing 12 items…")

        observerView.updateWindowSubtitle("Import Complete")
        XCTAssertEqual(window.subtitle, "Import Complete")

        observerView.updateWindowSubtitle("")
        XCTAssertEqual(window.subtitle, "")
    }

    func testNSWindowRegistrationDisablesResizingAndZoomButton() {
        let coordinator = LauncherMainWindowCoordinator(
            notificationCenter: NotificationCenter(),
            activateAppHandler: {}
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 612),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )

        coordinator.register(nsWindow: window)

        XCTAssertFalse(window.styleMask.contains(.resizable))
        XCTAssertEqual(window.standardWindowButton(.zoomButton)?.isEnabled, false)
    }

    func testWindowObserverViewGrowsAndShrinksContentHeightWhileAnchoringTopEdge() async {
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 200, width: 560, height: 420),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        let initialTopEdge = window.frame.maxY
        let observerView = LauncherMainWindowAccessor.WindowObserverView()
        window.contentView?.addSubview(observerView)

        observerView.updateContentHeight(580)
        await flushMainQueue()

        let grownContentSize = window.contentRect(forFrameRect: window.frame).size
        XCTAssertEqual(grownContentSize.width, LauncherWindowMetrics.idealWidth, accuracy: 0.5)
        XCTAssertEqual(grownContentSize.height, 580, accuracy: 0.5)
        XCTAssertEqual(window.contentMinSize, NSSize(width: LauncherWindowMetrics.idealWidth, height: 580))
        XCTAssertEqual(window.contentMaxSize, NSSize(width: LauncherWindowMetrics.idealWidth, height: 580))
        XCTAssertEqual(window.frame.maxY, initialTopEdge, accuracy: 1.0)

        observerView.updateContentHeight(380)
        await flushMainQueue()

        let shrunkContentSize = window.contentRect(forFrameRect: window.frame).size
        XCTAssertEqual(shrunkContentSize.width, LauncherWindowMetrics.idealWidth, accuracy: 0.5)
        XCTAssertEqual(shrunkContentSize.height, 380, accuracy: 0.5)
        XCTAssertEqual(window.contentMinSize, NSSize(width: LauncherWindowMetrics.idealWidth, height: 380))
        XCTAssertEqual(window.contentMaxSize, NSSize(width: LauncherWindowMetrics.idealWidth, height: 380))
        XCTAssertEqual(window.frame.maxY, initialTopEdge, accuracy: 1.0)
    }

    private func flushMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                continuation.resume()
            }
        }
    }
}
