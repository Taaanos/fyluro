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
    private enum WindowState {
        case closed
        case opening
        case open(primary: RegisteredWindow, extras: [RegisteredWindow])

        var windows: [RegisteredWindow] {
            switch self {
            case .closed, .opening:
                return []
            case let .open(primary, extras):
                return [primary] + extras
            }
        }
    }

    @Published private var state: WindowState = .closed

    var hasMainWindow: Bool {
        if case .open = state {
            return true
        }
        return false
    }

    private final class CloseObserverToken {
        private let center: NotificationCenter
        private let observer: NSObjectProtocol

        init(center: NotificationCenter, observer: NSObjectProtocol) {
            self.center = center
            self.observer = observer
        }

        deinit {
            center.removeObserver(observer)
        }
    }

    private struct RegisteredWindow {
        let id: ObjectIdentifier
        let window: any LauncherManagedWindow
        let closeObserverToken: CloseObserverToken?
    }

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

    /// Registers a real `NSWindow` as the main window and observes its close notification.
    func register(nsWindow: NSWindow) {
        nsWindow.identifier = LauncherWindowIdentifier.main
        nsWindow.tabbingMode = .disallowed

        let id = ObjectIdentifier(nsWindow)
        if state.windows.contains(where: { $0.id == id }) {
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

        if state.windows.contains(where: { $0.id == id }) {
            if let closeObserver {
                notificationCenter.removeObserver(closeObserver)
            }
            return
        }

        let entry = RegisteredWindow(
            id: id,
            window: window,
            closeObserverToken: closeObserver.map { CloseObserverToken(center: notificationCenter, observer: $0) }
        )
        switch state {
        case .closed, .opening:
            state = .open(primary: entry, extras: [])
        case let .open(primary, extras):
            state = .open(primary: primary, extras: extras + [entry])
        }
    }

    /// Removes a closed window from the active registry.
    func unregister(id: ObjectIdentifier) {
        let remaining = state.windows.filter { $0.id != id }
        setWindows(remaining, preservingOpeningIfEmpty: false)
        pruneDeadWindows()
    }

    /// Handles macOS Dock icon clicks and Finder reopen events.
    /// Brings an existing main window to front (unminimizing if needed), or opens a clean one.
    func handleReopen() -> Bool {
        pruneDeadWindows()

        if case let .open(primary, _) = state {
            if primary.window.isMiniaturized {
                primary.window.deminiaturize()
            }
            primary.window.bringToFront()
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

        switch state {
        case let .open(primary, _):
            if primary.window.isMiniaturized {
                primary.window.deminiaturize()
            }
            primary.window.bringToFront()
        case .opening:
            return
        case .closed:
            guard let openWindowHandler else {
                return
            }
            state = .opening
            openWindowHandler()
            Task { @MainActor [weak self] in
                guard let self, case .opening = self.state else {
                    return
                }
                self.state = .closed
            }
        }
    }

    private func pruneDeadWindows() {
        let alive = state.windows.filter { $0.window.isAlive }
        setWindows(alive, preservingOpeningIfEmpty: true)
    }

    private func setWindows(_ windows: [RegisteredWindow], preservingOpeningIfEmpty: Bool) {
        if let first = windows.first {
            state = .open(primary: first, extras: Array(windows.dropFirst()))
        } else if preservingOpeningIfEmpty, case .opening = state {
            state = .opening
        } else {
            state = .closed
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
