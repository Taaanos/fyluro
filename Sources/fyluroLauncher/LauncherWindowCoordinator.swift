import AppKit
import SwiftUI

enum LauncherSceneID {
    static let main = "main"
}

enum LauncherWindowIdentifier {
    static let main = NSUserInterfaceItemIdentifier("com.thanosam.fyluro.mainWindow")
}

/// Minimal window surface needed to enforce single-window reopen behavior.
@MainActor
protocol LauncherManagedWindow: AnyObject {
    var isAlive: Bool { get }
    var isMiniaturized: Bool { get }
    func deminiaturize()
    func bringToFront()
}

/// Adapts an AppKit `NSWindow` for `LauncherMainWindowCoordinator`.
@MainActor
final class LauncherAppKitManagedWindow: LauncherManagedWindow {
    private weak var window: NSWindow?

    init(window: NSWindow) {
        self.window = window
    }

    var isAlive: Bool { window != nil }
    var isMiniaturized: Bool { window?.isMiniaturized ?? false }

    func deminiaturize() {
        window?.deminiaturize(nil)
    }

    func bringToFront() {
        window?.makeKeyAndOrderFront(nil)
    }
}

/// Tracks the single main window and coordinates Dock reopen and New Window actions.
@MainActor
final class LauncherMainWindowCoordinator: ObservableObject {
    @Published private(set) var hasMainWindow = false

    private struct RegisteredWindow {
        let id: ObjectIdentifier
        let window: any LauncherManagedWindow
        let closeObserver: NSObjectProtocol?
    }

    private var registeredWindows: [RegisteredWindow] = []
    private var isOpeningNewWindow = false
    private let notificationCenter: NotificationCenter
    var openWindowHandler: (@MainActor () -> Void)?
    var activateAppHandler: @MainActor () -> Void

    init(
        notificationCenter: NotificationCenter = .default,
        activateAppHandler: (@MainActor () -> Void)? = nil
    ) {
        self.notificationCenter = notificationCenter
        self.activateAppHandler = activateAppHandler ?? { NSApp.activate(ignoringOtherApps: true) }
    }

    deinit {
        for entry in registeredWindows {
            if let observer = entry.closeObserver {
                notificationCenter.removeObserver(observer)
            }
        }
    }

    /// Registers a real `NSWindow` as the main window and observes its close notification.
    func register(nsWindow: NSWindow) {
        nsWindow.identifier = LauncherWindowIdentifier.main
        nsWindow.tabbingMode = .disallowed

        let id = ObjectIdentifier(nsWindow)
        if registeredWindows.contains(where: { $0.id == id }) {
            return
        }

        let observer = notificationCenter.addObserver(
            forName: NSWindow.willCloseNotification,
            object: nsWindow,
            queue: nil
        ) { [weak self] _ in
            if Thread.isMainThread {
                MainActor.assumeIsolated {
                    self?.unregister(id: id)
                }
            } else {
                Task { @MainActor [weak self] in
                    self?.unregister(id: id)
                }
            }
        }

        register(window: LauncherAppKitManagedWindow(window: nsWindow), id: id, closeObserver: observer)
    }

    /// Registers a managed window instance (used directly in unit tests).
    func register(window: any LauncherManagedWindow, id: ObjectIdentifier, closeObserver: NSObjectProtocol? = nil) {
        pruneDeadWindows()
        isOpeningNewWindow = false

        if registeredWindows.contains(where: { $0.id == id }) {
            if let closeObserver {
                notificationCenter.removeObserver(closeObserver)
            }
            updateHasMainWindow()
            return
        }

        registeredWindows.append(RegisteredWindow(id: id, window: window, closeObserver: closeObserver))
        updateHasMainWindow()
    }

    /// Removes a closed window from the active registry.
    func unregister(id: ObjectIdentifier) {
        registeredWindows.removeAll { entry in
            guard entry.id == id else { return false }
            if let observer = entry.closeObserver {
                notificationCenter.removeObserver(observer)
            }
            return true
        }
        pruneDeadWindows()
        updateHasMainWindow()
    }

    /// Handles macOS Dock icon clicks and Finder reopen events.
    /// Brings an existing main window to front (unminimizing if needed), or opens a clean one.
    func handleReopen() -> Bool {
        pruneDeadWindows()
        updateHasMainWindow()

        if let existing = registeredWindows.first?.window {
            if existing.isMiniaturized {
                existing.deminiaturize()
            }
            existing.bringToFront()
            activateAppHandler()
            return false
        }

        openNewWindowIfNeeded()
        activateAppHandler()
        return false
    }

    /// Opens a clean main window only when no main window is currently open.
    func openNewWindowIfNeeded() {
        pruneDeadWindows()
        updateHasMainWindow()

        if let existing = registeredWindows.first?.window {
            if existing.isMiniaturized {
                existing.deminiaturize()
            }
            existing.bringToFront()
            return
        }

        guard !isOpeningNewWindow, let openWindowHandler else {
            return
        }

        isOpeningNewWindow = true
        openWindowHandler()
        Task { @MainActor [weak self] in
            self?.isOpeningNewWindow = false
        }
    }

    private func pruneDeadWindows() {
        registeredWindows.removeAll { entry in
            if entry.window.isAlive {
                return false
            }
            if let observer = entry.closeObserver {
                notificationCenter.removeObserver(observer)
            }
            return true
        }
    }

    private func updateHasMainWindow() {
        let nextValue = !registeredWindows.isEmpty
        if hasMainWindow != nextValue {
            hasMainWindow = nextValue
        }
    }
}

/// Bridges AppKit reopen and tabbing behavior into the SwiftUI app lifecycle.
@MainActor
final class FyluroAppDelegate: NSObject, NSApplicationDelegate {
    weak var windowCoordinator: LauncherMainWindowCoordinator?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        windowCoordinator?.handleReopen() ?? true
    }
}

/// Attaches a transparent `NSView` so the main window registers itself once SwiftUI mounts it.
struct LauncherMainWindowAccessor: NSViewRepresentable {
    let onWindowAttached: (NSWindow) -> Void

    func makeNSView(context: Context) -> WindowObserverView {
        let view = WindowObserverView()
        view.onWindowAttached = onWindowAttached
        return view
    }

    func updateNSView(_ nsView: WindowObserverView, context: Context) {
        nsView.onWindowAttached = onWindowAttached
    }

    final class WindowObserverView: NSView {
        var onWindowAttached: ((NSWindow) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window {
                onWindowAttached?(window)
            }
        }
    }
}
