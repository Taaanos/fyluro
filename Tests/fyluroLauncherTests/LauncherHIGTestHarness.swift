import AppKit
import Foundation
import FyluroCore
import FyluroEngine
import SwiftUI
import XCTest
@testable import fyluroLauncher

final class StubCameraLabelsPreference: LauncherCameraLabelsPreferring, @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: Bool

    init(isEnabled: Bool = false) {
        self.storedValue = isEnabled
    }

    var isEnabled: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedValue
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            storedValue = newValue
        }
    }
}

final class StubCameraCatalogRemembering: LauncherCameraCatalogRemembering {
    var result: CameraUserCatalogLoadResult
    var movedAsideURL: URL?

    init(_ result: CameraUserCatalogLoadResult = .missing) {
        self.result = result
    }

    func load() -> CameraUserCatalogLoadResult {
        result
    }

    func save(_ entries: [String: String]) throws -> URL? {
        result = .loaded(entries)
        return movedAsideURL
    }
}

@MainActor
final class HostedHIGView {
    let window: NSWindow
    let hostingView: NSView
    private let targetWidth: CGFloat
    private let fixedHeight: CGFloat?

    private(set) var measuredFittingSize: CGSize = .zero
    private(set) var contentSize: CGSize = .zero

    init<Content: View>(
        width: CGFloat,
        fixedHeight: CGFloat? = nil,
        title: String = "Fyluro",
        subtitle: String = "",
        @ViewBuilder content: () -> Content
    ) {
        _ = NSApplication.shared

        self.targetWidth = width
        self.fixedHeight = fixedHeight

        let darkAppearance = NSAppearance(named: .darkAqua)
        let rootView = content()
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, .dark)

        let hosting = NSHostingView(rootView: rootView)
        hosting.appearance = darkAppearance

        let initialHeight = fixedHeight ?? 480
        let window = NSWindow(
            contentRect: NSRect(x: -4000, y: -4000, width: width, height: initialHeight),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.appearance = darkAppearance
        window.title = title
        window.subtitle = subtitle
        window.isReleasedWhenClosed = false
        window.contentView = hosting

        self.window = window
        self.hostingView = hosting

        relayout()
    }

    func relayout() {
        for _ in 0..<2 {
            window.contentView?.needsLayout = true
            hostingView.needsLayout = true
            window.layoutIfNeeded()
            hostingView.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }

        let naturalSize = hostingView.fittingSize
        measuredFittingSize = naturalSize

        let resolvedWidth = max(ceil(targetWidth), 1)
        let resolvedHeight = max(ceil(fixedHeight ?? naturalSize.height), 1)
        let resolvedSize = NSSize(width: resolvedWidth, height: resolvedHeight)

        if abs(window.contentLayoutRect.size.width - resolvedSize.width) > 0.5
            || abs(window.contentLayoutRect.size.height - resolvedSize.height) > 0.5 {
            window.contentMinSize = .zero
            window.contentMaxSize = NSSize(width: 10_000, height: 10_000)
            window.setContentSize(resolvedSize)
        }

        hostingView.frame = NSRect(origin: .zero, size: resolvedSize)
        window.layoutIfNeeded()
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        measuredFittingSize = hostingView.fittingSize
        contentSize = window.contentRect(forFrameRect: window.frame).size
    }

    func close() {
        window.close()
    }
}

@MainActor
final class HIGTempFixtures {
    let rootURL: URL
    let sourceURL: URL
    let destinationURL: URL
    let stagingURL: URL
    let receiptURL: URL
    let finalMediaURL: URL

    init() throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("fyluro-hig-tests-\(UUID().uuidString)", isDirectory: true)
        sourceURL = rootURL.appendingPathComponent("SOURCE_CARD", isDirectory: true)
        destinationURL = rootURL.appendingPathComponent("Library", isDirectory: true)
        stagingURL = destinationURL
            .appendingPathComponent("_ingest_staging", isDirectory: true)
            .appendingPathComponent("run-001", isDirectory: true)
        let receiptsDir = destinationURL.appendingPathComponent("_ingest_receipts", isDirectory: true)
        receiptURL = receiptsDir.appendingPathComponent("receipt.jsonl")
        finalMediaURL = destinationURL
            .appendingPathComponent("2026", isDirectory: true)
            .appendingPathComponent("202611", isDirectory: true)
            .appendingPathComponent("sony-a7iv", isDirectory: true)
            .appendingPathComponent("Photos", isDirectory: true)

        let fileManager = FileManager.default
        try fileManager.createDirectory(at: sourceURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: stagingURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: receiptsDir, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: finalMediaURL, withIntermediateDirectories: true)
        fileManager.createFile(atPath: receiptURL.path, contents: Data("{\"event\":\"session\"}\n".utf8))
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: rootURL)
    }
}

@MainActor
enum LauncherHIGTestHarness {
    static var shouldRenderSnapshots: Bool {
        ProcessInfo.processInfo.environment["FYLURO_RENDER_HIG_SCREENSHOTS"] == "1"
    }

    static var snapshotOutputDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["FYLURO_HIG_SCREENSHOT_DIR"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }

        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return repoRoot
            .appendingPathComponent("docs", isDirectory: true)
            .appendingPathComponent("ui-overhaul", isDirectory: true)
            .appendingPathComponent("after", isDirectory: true)
    }

    static func makeIsolatedViewModel(
        pathSchemeStore: LauncherPathSchemeSettingsStore? = nil
    ) -> LauncherViewModel {
        let suiteName = "fyluro-hig-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let resolvedPathSchemeStore = pathSchemeStore ?? LauncherPathSchemeSettingsStore(
            pathSchemeRemembering: StubLauncherPathSchemeRemembering(initialConfiguration: .default)
        )
        let viewModel = LauncherViewModel(
            sourceDefaulting: StubLauncherSourceDefaulting(path: nil),
            destinationRemembering: StubLauncherDestinationRemembering(initialPath: nil),
            destinationDefaulting: StubLauncherDestinationDefaulting(path: nil),
            pathSchemeSettingsStore: resolvedPathSchemeStore,
            filmModeRemembering: LauncherFilmModeMemory(userDefaults: defaults),
            cameraLabelsPreference: StubCameraLabelsPreference(isEnabled: false),
            finderOpening: StubLauncherFinderOpening(),
            workspaceNotificationCenter: NotificationCenter()
        )
        viewModel.hasPreparedLaunchDefaults = true
        return viewModel
    }

    static func cancelBackgroundTasks(on viewModel: LauncherViewModel) {
        viewModel.sourceScanTask?.cancel()
        viewModel.sourceScanTask = nil
        viewModel.destinationSpaceCheckTask?.cancel()
        viewModel.destinationSpaceCheckTask = nil
    }

    static func makeSampleSummary(
        photoCount: Int = 24,
        videoCount: Int = 4,
        audioCount: Int = 1,
        sidecarCount: Int = 3,
        totalBytes: Int64 = 1_420_000_000,
        unsortedCount: Int = 0,
        errorCount: Int = 0,
        warningCount: Int = 0,
        cameraCount: Int = 3
    ) -> LauncherSourceScopeSummary {
        let baseDate = Date(timeIntervalSince1970: 1_785_000_000)
        let endDate = baseDate.addingTimeInterval(3 * 86_400)
        let cameras = (1...max(cameraCount, 0)).map { index in
            LauncherSourceCameraSummary(
                label: "sony-a7m\(index)",
                fileCount: max(1, (photoCount + videoCount) / max(cameraCount, 1)),
                rawModelCode: "ILCE-7M\(index)"
            )
        }
        return LauncherSourceScopeSummary(
            itemCount: photoCount + videoCount + audioCount,
            photoCount: photoCount,
            videoCount: videoCount,
            audioCount: audioCount,
            sidecarCount: sidecarCount,
            totalBytes: totalBytes,
            unsortedCount: unsortedCount,
            errorCount: errorCount,
            warningCount: warningCount,
            cameraEntries: cameras,
            captureDateRangeStart: (photoCount + videoCount + audioCount) > 0 ? baseDate : nil,
            captureDateRangeEnd: (photoCount + videoCount + audioCount) > 0 ? endDate : nil
        )
    }

    static func seedThroughputTelemetry(on viewModel: LauncherViewModel, finalized: Bool) {
        var tracker = LauncherThroughputTracker()
        let start = Date(timeIntervalSince1970: 1_785_000_000)
        tracker.enterPhase(.copy, at: start)

        var copied: Int64 = 0
        for second in 1...6 {
            copied += 85_000_000 + Int64(second * 5_000_000)
            let timestamp = start.addingTimeInterval(TimeInterval(second))
            tracker.recordCopiedBytes(copied, at: timestamp)
            tracker.recordTick(at: timestamp)
        }

        if finalized {
            let verifyStart = start.addingTimeInterval(6.5)
            tracker.enterPhase(.verify, at: verifyStart)
            var verified: Int64 = 0
            var lastVerifyTimestamp = verifyStart
            for step in 1...5 {
                verified += copied / 5
                let timestamp = verifyStart.addingTimeInterval(TimeInterval(step))
                tracker.recordVerifiedBytes(min(copied, verified), at: timestamp)
                tracker.recordTick(at: timestamp)
                lastVerifyTimestamp = timestamp
            }
            tracker.finalize(at: lastVerifyTimestamp, copyDurationMs: 6_500, verifyDurationMs: 5_700)
        }

        viewModel.throughputTracker = tracker
        viewModel.totalCopiedBytes = tracker.totalCopiedBytes
        viewModel.totalVerifiedBytes = tracker.totalVerifiedBytes
    }

    static func assertNoHorizontalOverflow(
        _ hosted: HostedHIGView,
        maxWidth: CGFloat,
        context: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertLessThanOrEqual(
            hosted.measuredFittingSize.width,
            maxWidth + 1.0,
            "\(context): fitting width \(hosted.measuredFittingSize.width) exceeded \(maxWidth)",
            file: file,
            line: line
        )
    }

    static func assertEllipsisConvention(
        titles: [String],
        context: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let openerBases = Set(["Choose", "Change", "Film Mode", "Edit"])
        let immediateTitles = Set([
            "Import",
            "Import Anyway",
            "Turn Off",
            "Stop Import",
            "Show in Finder",
            "Import Another Card",
            "Show Receipt",
            "Show Staging",
            "Show Destination",
            "Back to Setup",
            "Cancel",
            "Apply",
            "Reset to Default",
            "Add",
        ])

        for rawTitle in titles {
            let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else {
                continue
            }

            XCTAssertFalse(
                title.contains("..."),
                "\(context): button '\(title)' uses three ASCII dots instead of Unicode ellipsis",
                file: file,
                line: line
            )

            let stripped = title.hasSuffix("…") ? String(title.dropLast()) : title
            if openerBases.contains(stripped) {
                XCTAssertTrue(
                    title.hasSuffix("…"),
                    "\(context): dialog/sheet trigger '\(title)' must end with ellipsis '…'",
                    file: file,
                    line: line
                )
            } else if immediateTitles.contains(stripped) {
                XCTAssertFalse(
                    title.hasSuffix("…"),
                    "\(context): immediate action '\(title)' must not end with ellipsis '…'",
                    file: file,
                    line: line
                )
            }
        }
    }

    static func assertResultActionBarSingleRow(
        secondaryActions: [ResultAction],
        primaryAction: ResultAction,
        availableWidth: CGFloat = LauncherWindowMetrics.idealWidth - 36,
        context: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let actualHost = HostedHIGView(width: availableWidth, title: context) {
            ResultActionBar(secondaryActions: secondaryActions, primaryAction: primaryAction)
                .frame(width: availableWidth)
        }
        defer { actualHost.close() }

        let baselineHost = HostedHIGView(width: availableWidth, title: "\(context) (baseline)") {
            ResultActionBar(secondaryActions: [], primaryAction: primaryAction)
                .frame(width: availableWidth)
        }
        defer { baselineHost.close() }

        XCTAssertLessThanOrEqual(
            actualHost.measuredFittingSize.width,
            availableWidth + 1.0,
            "\(context): ResultActionBar width \(actualHost.measuredFittingSize.width) exceeded \(availableWidth)",
            file: file,
            line: line
        )
        XCTAssertEqual(
            actualHost.measuredFittingSize.height,
            baselineHost.measuredFittingSize.height,
            accuracy: 1.0,
            "\(context): ResultActionBar wrapped to multiple rows (\(actualHost.measuredFittingSize.height) vs baseline \(baselineHost.measuredFittingSize.height))",
            file: file,
            line: line
        )
    }

    @discardableResult
    static func writeDarkModeSnapshot(
        named fileName: String,
        hosted: HostedHIGView,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> URL {
        let directory = snapshotOutputDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let resolvedName = fileName.hasSuffix(".png") ? fileName : "\(fileName).png"
        let outputURL = directory.appendingPathComponent(resolvedName)

        let bounds = hosted.hostingView.bounds
        XCTAssertGreaterThan(bounds.width, 0, "\(fileName): bounds width must be positive", file: file, line: line)
        XCTAssertGreaterThan(bounds.height, 0, "\(fileName): bounds height must be positive", file: file, line: line)

        var pngData: Data?
        NSAppearance(named: .darkAqua)?.performAsCurrentDrawingAppearance {
            guard let rep = hosted.hostingView.bitmapImageRepForCachingDisplay(in: bounds) else {
                return
            }
            rep.size = bounds.size
            hosted.hostingView.cacheDisplay(in: bounds, to: rep)
            pngData = rep.representation(using: .png, properties: [:])
        }

        let data = try XCTUnwrap(pngData, "\(fileName): failed to encode Dark Mode PNG", file: file, line: line)
        XCTAssertFalse(data.isEmpty, "\(fileName): PNG data was empty", file: file, line: line)

        let decoded = NSImage(data: data)
        XCTAssertNotNil(decoded, "\(fileName): PNG data could not be decoded by NSImage", file: file, line: line)
        if let decoded {
            XCTAssertGreaterThan(decoded.size.width, 0, file: file, line: line)
            XCTAssertGreaterThan(decoded.size.height, 0, file: file, line: line)
        }

        try data.write(to: outputURL, options: .atomic)
        return outputURL
    }
}
