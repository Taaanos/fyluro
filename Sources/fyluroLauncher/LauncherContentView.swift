import SwiftUI

struct LauncherContentView: View {
    @StateObject private var viewModel: LauncherViewModel
    @State private var isFilmModeSheetPresented = false
    @State private var measuredContentHeight: CGFloat = 0
    @ObservedObject private var cameraCatalogStore: LauncherCameraCatalogStore
    private let windowCoordinator: LauncherMainWindowCoordinator?

    init(
        pathSchemeSettingsStore: LauncherPathSchemeSettingsStore? = nil,
        cameraCatalogStore: LauncherCameraCatalogStore? = nil,
        transferSettingsStore: LauncherTransferSettingsStore? = nil,
        windowCoordinator: LauncherMainWindowCoordinator? = nil
    ) {
        let store = pathSchemeSettingsStore ?? LauncherPathSchemeSettingsStore()
        _viewModel = StateObject(
            wrappedValue: LauncherViewModel(
                pathSchemeSettingsStore: store,
                transferSettingsStore: transferSettingsStore
            )
        )
        _cameraCatalogStore = ObservedObject(wrappedValue: cameraCatalogStore ?? LauncherCameraCatalogStore())
        self.windowCoordinator = windowCoordinator
    }

    @MainActor
    init(
        viewModel: LauncherViewModel,
        cameraCatalogStore: LauncherCameraCatalogStore? = nil,
        windowCoordinator: LauncherMainWindowCoordinator? = nil
    ) {
        _viewModel = StateObject(wrappedValue: viewModel)
        _cameraCatalogStore = ObservedObject(wrappedValue: cameraCatalogStore ?? LauncherCameraCatalogStore())
        self.windowCoordinator = windowCoordinator
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch viewModel.uiState {
            case .idle, .ready:
                setupSection
            case .running:
                importingSection
            case .success:
                completeSection
            case .failure:
                failureSection
            }
        }
        .padding(18)
        .frame(width: LauncherWindowMetrics.idealWidth, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
        .background(
            GeometryReader { proxy in
                Color.clear
                    .preference(key: LauncherContentHeightPreferenceKey.self, value: proxy.size.height)
            }
        )
        .task {
            viewModel.prepareDefaultsOnLaunch()
        }
        .background(
            LauncherMainWindowAccessor(
                targetContentHeight: measuredContentHeight,
                windowSubtitle: viewModel.windowSubtitle
            ) { window in
                windowCoordinator?.register(nsWindow: window)
            }
        )
        .onPreferenceChange(LauncherContentHeightPreferenceKey.self) { height in
            guard height > 0 else {
                return
            }
            measuredContentHeight = height
        }
        .onChange(of: viewModel.setupInventoryCameraEntries) { entries in
            cameraCatalogStore.updateDetectedCameras(from: entries)
        }
    }

    private var setupSection: some View {
        LauncherPaneLayout(spacing: 14) {
            VStack(alignment: .leading, spacing: 14) {
                LauncherSetupRoutePanel(viewModel: viewModel)

                if !viewModel.sourcePath.isEmpty {
                    LauncherSourceInventoryPanel(viewModel: viewModel, cameraCatalogStore: cameraCatalogStore)
                } else {
                    LauncherEmptySourcePanel()
                }

                if let dropNotice = viewModel.setupDropNoticeText {
                    NoticeBanner(tone: .attention, text: dropNotice)
                }
            }
        } bottom: {
            VStack(alignment: .leading, spacing: 12) {
                if let summary = viewModel.filmModeSummaryText {
                    LauncherFilmModeSummaryRow(
                        summary: summary,
                        isDisabled: viewModel.isRunning,
                        onEdit: { isFilmModeSheetPresented = true },
                        onTurnOff: viewModel.disableFilmMode
                    )
                }

                Divider()

                HStack(alignment: .center, spacing: 12) {
                    if !viewModel.filmModeEnabled {
                        LauncherFilmModeButtonRow(
                            isDisabled: viewModel.isRunning,
                            onOpen: { isFilmModeSheetPresented = true }
                        )
                    }

                    Spacer(minLength: 12)

                    startImportButton
                }
            }
        }
        .sheet(isPresented: $isFilmModeSheetPresented) {
            LauncherFilmModeSheet(
                viewModel: viewModel,
                editing: viewModel.filmModeState.configuration
            )
        }
        .folderDropTarget(
            isEnabled: !viewModel.isRunning,
            cornerRadius: LauncherRadius.card,
            onDropURLs: viewModel.acceptDroppedSource
        )
    }

    private var startImportButton: some View {
        Button("Import", action: viewModel.startIngest)
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .keyboardShortcut(.defaultAction)
            .disabled(!viewModel.isImportReady)
            .fixedSize()
    }

    private var importingSection: some View {
        LauncherPaneLayout(spacing: 14) {
            VStack(alignment: .leading, spacing: 14) {
                LauncherImportRoutePanel(
                    sourceName: viewModel.importSourceDisplayName,
                    sourcePath: viewModel.importSourceDisplayPath,
                    destinationName: viewModel.importDestinationDisplayName,
                    destinationPath: viewModel.importDestinationDisplayPath,
                    status: .running
                )

                VStack(alignment: .leading, spacing: 8) {
                    Text(viewModel.importingBodyTitle)
                        .font(.headline)

                    ProgressView(value: viewModel.importingProgressFraction)
                        .controlSize(.large)

                    if viewModel.isImportScanPhase {
                        Text(viewModel.importingScanProgressText)
                            .font(.subheadline)

                        Text(viewModel.importingScanHeartbeatText)
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Text(viewModel.importingScanActivityText ?? " ")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .accessibilityHidden(viewModel.importingScanActivityText == nil)
                    } else {
                        Text(viewModel.importingETAWithRateText)
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)

                        // Reserve one caption line so the window height does not jump when the active file clears.
                        Text(viewModel.importingCurrentFileText ?? " ")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .accessibilityHidden(viewModel.importingCurrentFileText == nil)
                    }
                }

                if !viewModel.isImportScanPhase && viewModel.shouldShowImportingThroughputToggle {
                    activityDisclosureSection(
                        isCompleted: false,
                        liveBytesPerSecond: viewModel.importingLiveBytesPerSecond
                    )
                }
            }
        } bottom: {
            VStack(alignment: .leading, spacing: 12) {
                Divider()

                HStack(alignment: .center, spacing: 12) {
                    Text(viewModel.importingPhaseDescription)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Spacer(minLength: 12)

                    Button("Stop Import", action: viewModel.stopIngest)
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                        .disabled(!viewModel.isRunning)
                }
            }
        }
    }

    private var completeSection: some View {
        LauncherPaneLayout(spacing: 14) {
            VStack(alignment: .leading, spacing: 14) {
                LauncherImportRoutePanel(
                    sourceName: viewModel.importSourceDisplayName,
                    sourcePath: viewModel.importSourceDisplayPath,
                    destinationName: viewModel.importDestinationDisplayName,
                    destinationPath: viewModel.importDestinationDisplayPath,
                    status: viewModel.resultRouteStatus,
                    onOpenSource: viewModel.canOpenSource ? { viewModel.openSource() } : nil
                )

                completionSummary

                if viewModel.hasThroughputTelemetry {
                    activityDisclosureSection(
                        isCompleted: true,
                        liveBytesPerSecond: nil
                    )
                }

                if viewModel.hasRecordedErrors {
                    NoticeBanner(tone: .attention, title: viewModel.completionWarningTitle) {
                        if viewModel.completionWarningEntries.count > LauncherWindowMetrics.maxVisibleCompletionWarningRows {
                            ScrollView(.vertical) {
                                completionWarningRows
                                    .padding(.trailing, 14)
                            }
                            .frame(height: LauncherWindowMetrics.completionWarningListMaxHeight)
                        } else {
                            completionWarningRows
                        }

                        Text("Check the receipt for full details.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }
        } bottom: {
            ResultActionBar(
                secondaryActions: completionSecondaryActions,
                primaryAction: completionPrimaryAction
            )
        }
    }

    private var completionWarningRows: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(viewModel.completionWarningEntries) { entry in
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.path)
                        .font(.caption.monospaced())
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(entry.message)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func activityDisclosureSection(
        isCompleted: Bool,
        liveBytesPerSecond: Double?
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                throughputToggleButton
                Spacer()
            }
            if viewModel.showThroughputGraph {
                LauncherThroughputGraphView(
                    tracker: viewModel.throughputTracker,
                    isCompleted: isCompleted,
                    liveBytesPerSecond: liveBytesPerSecond,
                    formattedTotalCopied: viewModel.formattedTotalCopiedBytes,
                    formattedTotalVerified: viewModel.formattedTotalVerifiedBytes
                )
            }
        }
    }

    private var throughputToggleButton: some View {
        Button {
            viewModel.showThroughputGraph.toggle()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .rotationEffect(.degrees(viewModel.showThroughputGraph ? 90 : 0))
                    .frame(width: 10)
                Image(systemName: "waveform.path.ecg")
                    .font(.caption)
                Text("Activity")
                    .font(.caption.weight(.medium))
            }
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(viewModel.showThroughputGraph ? "Hide import activity graph" : "Show import activity graph")
    }

    var completionPrimaryAction: ResultAction {
        Self.completionPrimaryAction(for: viewModel)
    }

    var completionSecondaryActions: [ResultAction] {
        Self.completionSecondaryActions(for: viewModel)
    }

    @MainActor
    static func completionPrimaryAction(for viewModel: LauncherViewModel) -> ResultAction {
        if viewModel.canOpenNewFinalMediaDirectories {
            return ResultAction(title: "Show in Finder", action: viewModel.openNewFinalMediaDirectories)
        }
        return importAnotherCardAction(for: viewModel)
    }

    @MainActor
    static func completionSecondaryActions(for viewModel: LauncherViewModel) -> [ResultAction] {
        if viewModel.canOpenNewFinalMediaDirectories {
            return [importAnotherCardAction(for: viewModel)]
        }
        return []
    }

    @MainActor
    private static func importAnotherCardAction(for viewModel: LauncherViewModel) -> ResultAction {
        ResultAction(title: "Import Another Card", action: viewModel.importAnotherCard)
    }

    private var completionSummary: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(viewModel.completionSummaryTitle)
                        .font(.headline)
                    Text(viewModel.completionOutcomeText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Divider()

                VStack(alignment: .leading, spacing: 4) {
                    completionStatGrid

                    if let sidecarNote = viewModel.completionSidecarNoteText {
                        Text(sidecarNote)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if let filmModeText = viewModel.completionFilmModeText {
                    Divider()
                    Label(filmModeText, systemImage: "film")
                        .font(.subheadline)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)

                    if let noticeText = viewModel.filmModeRawSkipNoticeText {
                        NoticeBanner(tone: .attention, text: noticeText)
                    }
                } else if let noticeText = viewModel.filmModeRawSkipNoticeText {
                    NoticeBanner(tone: .attention, text: noticeText)
                }

                HStack(alignment: .center, spacing: 10) {
                    Text(viewModel.completionReceiptText)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Spacer(minLength: 8)

                    Button("Show Receipt", action: viewModel.openReceipt)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(!viewModel.canOpenReceipt)
                        .fixedSize()
                }
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var completionStatGrid: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 12) {
            ForEach(Array(viewModel.completionStatRows.enumerated()), id: \.offset) { _, row in
                GridRow {
                    ForEach(row) { stat in
                        StatItem(title: stat.title, value: stat.value)
                    }
                }
            }
        }
    }

    private var failureSection: some View {
        LauncherPaneLayout(spacing: 14) {
            VStack(alignment: .leading, spacing: 14) {
                LauncherImportRoutePanel(
                    sourceName: viewModel.importSourceDisplayName,
                    sourcePath: viewModel.importSourceDisplayPath,
                    destinationName: viewModel.importDestinationDisplayName,
                    destinationPath: viewModel.importDestinationDisplayPath,
                    status: viewModel.resultRouteStatus,
                    onOpenSource: viewModel.canOpenSource ? { viewModel.openSource() } : nil
                )

                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(viewModel.failureSummaryTitle)
                                .font(.headline)

                            Text(viewModel.failureMessage)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                // Let the message wrap. Without this the window is sized for one line and cuts the text.
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)

                            if let safetyNote = viewModel.failureSafetyNoteText {
                                Text(safetyNote)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }

                        if let evidenceText = viewModel.failureEvidenceText {
                            Divider()

                            HStack(alignment: .center, spacing: 8) {
                                Text(evidenceText)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)

                                Spacer(minLength: 8)

                                ForEach(failureEvidenceActions) { item in
                                    Button(item.title, action: item.action)
                                        .buttonStyle(.bordered)
                                        .controlSize(.small)
                                        .fixedSize()
                                }
                            }
                        }
                    }
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                if viewModel.hasThroughputTelemetry {
                    activityDisclosureSection(
                        isCompleted: true,
                        liveBytesPerSecond: nil
                    )
                }
            }
        } bottom: {
            ResultActionBar(
                secondaryActions: failureSecondaryActions,
                primaryAction: failurePrimaryAction
            )
        }
    }

    var failureEvidenceActions: [ResultAction] {
        Self.failureEvidenceActions(for: viewModel)
    }

    var failurePrimaryAction: ResultAction {
        Self.failurePrimaryAction(for: viewModel)
    }

    var failureSecondaryActions: [ResultAction] {
        Self.failureSecondaryActions(for: viewModel)
    }

    @MainActor
    static func failureEvidenceActions(for viewModel: LauncherViewModel) -> [ResultAction] {
        var actions: [ResultAction] = []
        if viewModel.canOpenStagingFolder {
            actions.append(ResultAction(title: "Show Staging", action: viewModel.openStagingFolder))
        }
        if viewModel.canOpenReceipt {
            actions.append(ResultAction(title: "Show Receipt", action: viewModel.openReceipt))
        }
        return actions
    }

    @MainActor
    static func failurePrimaryAction(for viewModel: LauncherViewModel) -> ResultAction {
        ResultAction(title: "Back to Setup", action: viewModel.returnToSetup)
    }

    @MainActor
    static func failureSecondaryActions(for viewModel: LauncherViewModel) -> [ResultAction] {
        var actions: [ResultAction] = []
        if viewModel.canOpenDestination {
            actions.append(ResultAction(title: "Show Destination", action: viewModel.openDestination))
        }
        actions.append(importAnotherCardAction(for: viewModel))
        return actions
    }
}

private struct LauncherPaneLayout<Top: View, Bottom: View>: View {
    let spacing: CGFloat
    @ViewBuilder let top: Top
    @ViewBuilder let bottom: Bottom

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            top
                .fixedSize(horizontal: false, vertical: true)
            bottom
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct LauncherContentHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
