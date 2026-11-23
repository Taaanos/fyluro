import AppKit
import SwiftUI

enum LauncherSceneID {
    static let main = "main"
}

enum LauncherWindowIdentifier {
    static let main = NSUserInterfaceItemIdentifier("com.thanosam.fyluro.mainWindow")
}

@MainActor
protocol LauncherManagedWindow: AnyObject {
    var isAlive: Bool { get }
    var isMiniaturized: Bool { get }
    func deminiaturize()
    func bringToFront()
}

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

    func register(nsWindow: NSWindow) {
        nsWindow.identifier = LauncherWindowIdentifier.main
        nsWindow.tabbingMode = .disallowed
        nsWindow.collectionBehavior.remove([.fullScreenPrimary, .fullScreenAuxiliary])
        nsWindow.collectionBehavior.insert(.fullScreenNone)

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

    func unregister(id: ObjectIdentifier) {
        let remaining = state.windows.filter { $0.id != id }
        setWindows(remaining, preservingOpeningIfEmpty: false)
        pruneDeadWindows()
    }

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

struct LauncherMainWindowAccessor: NSViewRepresentable {
    let targetContentHeight: CGFloat
    let windowSubtitle: String
    let onWindowAttached: (NSWindow) -> Void

    func makeNSView(context: Context) -> WindowObserverView {
        let view = WindowObserverView()
        view.onWindowAttached = onWindowAttached
        view.updateWindowSubtitle(windowSubtitle)
        view.updateContentHeight(targetContentHeight)
        return view
    }

    func updateNSView(_ nsView: WindowObserverView, context: Context) {
        nsView.onWindowAttached = onWindowAttached
        nsView.updateWindowSubtitle(windowSubtitle)
        nsView.updateContentHeight(targetContentHeight)
    }

    final class WindowObserverView: NSView {
        var onWindowAttached: ((NSWindow) -> Void)?
        private var targetContentHeight: CGFloat = 0
        private var targetWindowSubtitle = ""
        private var hasAppliedInitialHeight = false
        private var pendingResizeWorkItem: DispatchWorkItem?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else {
                return
            }
            onWindowAttached?(window)
            applyWindowSubtitleIfNeeded()
            scheduleResize(animate: false)
        }

        func updateWindowSubtitle(_ subtitle: String) {
            guard targetWindowSubtitle != subtitle else {
                return
            }
            targetWindowSubtitle = subtitle
            applyWindowSubtitleIfNeeded()
        }

        func updateContentHeight(_ height: CGFloat) {
            guard height > 0, abs(targetContentHeight - height) > 0.5 else {
                return
            }
            targetContentHeight = height
            scheduleResize(animate: hasAppliedInitialHeight)
        }

        private func applyWindowSubtitleIfNeeded() {
            guard let window, window.subtitle != targetWindowSubtitle else {
                return
            }
            window.subtitle = targetWindowSubtitle
        }

        private func scheduleResize(animate: Bool) {
            pendingResizeWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                self?.applyContentHeightIfNeeded(animate: animate)
            }
            pendingResizeWorkItem = workItem
            DispatchQueue.main.async(execute: workItem)
        }

        private func applyContentHeightIfNeeded(animate: Bool) {
            guard let window, targetContentHeight > 0 else {
                return
            }
            let targetHeight = ceil(targetContentHeight)
            let currentContentSize = window.contentRect(forFrameRect: window.frame).size
            window.contentMinSize = NSSize(width: LauncherWindowMetrics.minWidth, height: targetHeight)
            window.contentMaxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: targetHeight)
            hasAppliedInitialHeight = true
            guard abs(currentContentSize.height - targetHeight) > 0.5 else {
                return
            }
            let targetFrameSize = window.frameRect(
                forContentRect: NSRect(origin: .zero, size: CGSize(width: currentContentSize.width, height: targetHeight))
            ).size
            var newFrame = window.frame
            // Keep the top edge anchored so expanding or collapsing content does not shift the title bar.
            newFrame.origin.y += newFrame.height - targetFrameSize.height
            newFrame.size.height = targetFrameSize.height
            if let visibleFrame = window.screen?.visibleFrame, newFrame.minY < visibleFrame.minY {
                newFrame.origin.y = visibleFrame.minY
            }
            window.setFrame(newFrame, display: true, animate: animate)
        }
    }
}
