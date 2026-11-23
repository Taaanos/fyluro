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

                if let notice = viewModel.setupStatusNoticeText {
                    NoticeBanner(tone: .attention, text: notice, emphasizedText: true)
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
                        ScrollView(.vertical, showsIndicators: viewModel.completionWarningEntries.count > LauncherWindowMetrics.maxVisibleCompletionWarningRows) {
                            LazyVStack(alignment: .leading, spacing: 6) {
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
                        .frame(maxHeight: LauncherWindowMetrics.completionWarningListMaxHeight)

                        Text("See \"View Receipt\" for full details.")
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
        .accessibilityLabel(viewModel.showThroughputGraph ? "Hide transfer activity graph" : "Show transfer activity graph")
    }

    private var completionPrimaryAction: ResultAction {
        if viewModel.canOpenNewFinalMediaDirectories {
            return ResultAction(title: "Show in Finder", action: viewModel.openNewFinalMediaDirectories)
        }
        return importAnotherCardAction
    }

    private var completionSecondaryActions: [ResultAction] {
        if viewModel.canOpenNewFinalMediaDirectories {
            return [importAnotherCardAction]
        }
        return []
    }

    private var importAnotherCardAction: ResultAction {
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

                completionStatGrid

                if let sidecarNote = viewModel.completionSidecarNoteText {
                    Text(sidecarNote)
                        .font(.caption)
                        .foregroundStyle(.secondary)
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

                    Button("View Receipt", action: viewModel.openReceipt)
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
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(viewModel.completionStatRows.enumerated()), id: \.offset) { _, row in
                HStack(alignment: .top, spacing: 10) {
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
                    VStack(alignment: .leading, spacing: 6) {
                        Text(viewModel.failureSummaryTitle)
                            .font(.headline)

                        Text(viewModel.failureMessage)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            // Let the message wrap. Without this the window is sized for one line and cuts the text.
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        } bottom: {
            ResultActionBar(
                secondaryActions: [
                    ResultAction(title: "View Receipt", isEnabled: viewModel.canOpenReceipt, action: viewModel.openReceipt),
                    ResultAction(title: "Open Destination", isEnabled: viewModel.canOpenDestination, action: viewModel.openDestination),
                    ResultAction(
                        title: "Show Staging Folder",
                        isEnabled: viewModel.canOpenStagingFolder,
                        action: viewModel.openStagingFolder
                    ),
                ],
                primaryAction: importAnotherCardAction
            )
        }
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
