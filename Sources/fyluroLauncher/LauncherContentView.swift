import SwiftUI

struct LauncherContentView: View {
    @StateObject private var viewModel: LauncherViewModel
    @State private var isFilmModeSheetPresented = false
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
        .frame(
            minWidth: LauncherWindowMetrics.minWidth,
            idealWidth: LauncherWindowMetrics.idealWidth,
            minHeight: LauncherWindowMetrics.minContentHeight,
            alignment: .topLeading
        )
        // The height of a state is its content height, and never less than the minimum.
        // Without this the window keeps its old height when a state needs more, and cuts the bottom.
        .fixedSize(horizontal: false, vertical: true)
        .task {
            viewModel.prepareDefaultsOnLaunch()
        }
        .background(
            LauncherMainWindowAccessor { window in
                windowCoordinator?.register(nsWindow: window)
            }
        )
        .onChange(of: viewModel.setupInventoryCameraEntries) { entries in
            cameraCatalogStore.updateDetectedCameras(from: entries)
        }
    }

    private var setupSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            LauncherSetupRoutePanel(viewModel: viewModel)

            if !viewModel.sourcePath.isEmpty {
                LauncherSourceInventoryPanel(viewModel: viewModel, cameraCatalogStore: cameraCatalogStore)
            }

            Spacer(minLength: 0)

            LauncherFilmModeToggleRow(viewModel: viewModel, isFilmModeSheetPresented: $isFilmModeSheetPresented)

            startImportButton

            if let notice = viewModel.setupStatusNoticeText {
                NoticeBanner(tone: .attention, text: notice, emphasizedText: true)
            }
        }
        .folderDropTarget(
            isEnabled: !viewModel.isRunning,
            cornerRadius: LauncherRadius.card,
            onDropURLs: viewModel.acceptDroppedSource
        )
    }

    private var startImportButton: some View {
        Button(action: viewModel.startIngest) {
            Text("Import")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .keyboardShortcut(.defaultAction)
        .disabled(!viewModel.isImportReady)
    }

    private var importingSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(viewModel.importingTitle)
                .font(.title3.weight(.semibold))

            LauncherImportRoutePanel(
                sourceName: viewModel.importSourceDisplayName,
                sourcePath: viewModel.importSourceDisplayPath,
                destinationName: viewModel.importDestinationDisplayName,
                destinationPath: viewModel.importDestinationDisplayPath,
                status: .running
            )

            ProgressView(value: viewModel.importingProgressFraction)
                .controlSize(.large)

            if viewModel.isImportScanPhase {
                Text(viewModel.importingScanProgressText)
                    .font(.body)

                Text(viewModel.importingScanHeartbeatText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                if let currentFile = viewModel.importingScanActivityText {
                    Text(currentFile)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            } else {
                Text(viewModel.importingProgressText)
                    .font(.body)

                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(viewModel.importingETAWithRateText)
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    if viewModel.shouldShowImportingThroughputToggle {
                        throughputToggleButton
                    }
                }

                if let currentFile = viewModel.importingCurrentFileText {
                    Text(currentFile)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                if viewModel.shouldShowImportingThroughputToggle && viewModel.showThroughputGraph {
                    LauncherThroughputGraphView(
                        tracker: viewModel.throughputTracker,
                        isCompleted: false,
                        liveBytesPerSecond: viewModel.importingLiveBytesPerSecond,
                        formattedTotalCopied: viewModel.formattedTotalCopiedBytes,
                        formattedTotalVerified: viewModel.formattedTotalVerifiedBytes
                    )
                }
            }

            Spacer(minLength: 0)

            HStack {
                Button("Stop Import", action: viewModel.stopIngest)
                    .buttonStyle(.bordered)
                    .disabled(!viewModel.isRunning)
                Spacer()
                Text(viewModel.importingPhaseDescription)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var completeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Import Complete")
                .font(.title3.weight(.semibold))

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
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        throughputToggleButton
                        Spacer()
                    }
                    if viewModel.showThroughputGraph {
                        LauncherThroughputGraphView(
                            tracker: viewModel.throughputTracker,
                            isCompleted: true,
                            liveBytesPerSecond: nil,
                            formattedTotalCopied: viewModel.formattedTotalCopiedBytes,
                            formattedTotalVerified: viewModel.formattedTotalVerifiedBytes
                        )
                    }
                }
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

            Spacer(minLength: 0)

            ResultActionBar(
                secondaryActions: completionSecondaryActions,
                primaryAction: completionPrimaryAction
            )
        }
    }

    private var throughputToggleButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.16)) {
                viewModel.showThroughputGraph.toggle()
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "waveform.path.ecg")
                    .font(.caption)
                Text("Activity")
                    .font(.caption.weight(.medium))
                Image(systemName: viewModel.showThroughputGraph ? "chevron.up" : "chevron.down")
                    .font(.caption2)
            }
            .foregroundStyle(.secondary)
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
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(viewModel.completionItemsText)
                    .font(.headline)
                Text(viewModel.completionOutcomeText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Divider()

            completionStatGrid

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
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Surface())
    }

    private var completionStatGrid: some View {
        let rows = stride(from: 0, to: viewModel.completionStats.count, by: 4).map {
            Array(viewModel.completionStats[$0..<min($0 + 4, viewModel.completionStats.count)])
        }
        return Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 12) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                GridRow {
                    ForEach(row) { stat in
                        StatItem(title: stat.title, value: stat.value)
                    }
                }
            }
        }
    }

    private var failureSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(viewModel.failureTitle)
                .font(.title3.weight(.semibold))

            LauncherImportRoutePanel(
                sourceName: viewModel.importSourceDisplayName,
                sourcePath: viewModel.importSourceDisplayPath,
                destinationName: viewModel.importDestinationDisplayName,
                destinationPath: viewModel.importDestinationDisplayPath,
                status: viewModel.resultRouteStatus,
                onOpenSource: viewModel.canOpenSource ? { viewModel.openSource() } : nil
            )

            Text(viewModel.failureMessage)
                .font(.body)
                .foregroundStyle(.primary)
                // Let the message wrap. Without this the window is sized for one line and cuts the text.
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)

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
