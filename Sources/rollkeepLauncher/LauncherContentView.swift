import SwiftUI

struct LauncherContentView: View {
    @StateObject private var viewModel: LauncherViewModel
    @State private var isFilmModeSheetPresented = false
    @ObservedObject private var cameraCatalogStore: LauncherCameraCatalogStore

    init(
        pathSchemeSettingsStore: LauncherPathSchemeSettingsStore? = nil,
        cameraCatalogStore: LauncherCameraCatalogStore? = nil
    ) {
        let store = pathSchemeSettingsStore ?? LauncherPathSchemeSettingsStore()
        _viewModel = StateObject(wrappedValue: LauncherViewModel(pathSchemeSettingsStore: store))
        _cameraCatalogStore = ObservedObject(wrappedValue: cameraCatalogStore ?? LauncherCameraCatalogStore())
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
        // Every state has the same minimum height, so the window does not change size
        // when the state changes. The main action of each state sits at the bottom.
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
        .onChange(of: viewModel.setupInventoryCameraEntries) { entries in
            cameraCatalogStore.updateDetectedCameras(from: entries)
        }
        .onChange(of: cameraCatalogStore.revision) { _ in
            rescanForUpdatedCameraLabels()
        }
    }

    /// Labels are computed at scan time, so a catalog edit needs a fresh
    /// preview scan to show up in the inventory. Never while an import runs:
    /// a run labels from its own scan and must not be disturbed.
    private func rescanForUpdatedCameraLabels() {
        switch viewModel.uiState {
        case .idle, .ready:
            viewModel.scheduleSourceScanIfNeeded(keepingInventory: true)
        case .running, .success, .failure:
            break
        }
    }

    private var setupSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            LauncherSetupRoutePanel(viewModel: viewModel)

            if !viewModel.sourcePath.isEmpty {
                LauncherSourceInventoryPanel(viewModel: viewModel)
            }

            Spacer(minLength: 0)

            LauncherFilmModeToggleRow(viewModel: viewModel, isFilmModeSheetPresented: $isFilmModeSheetPresented)

            startImportButton

            if let notice = viewModel.setupStatusNoticeText {
                NoticeBanner(tone: .attention, text: notice, emphasizedText: true)
            }
        }
        // The whole window takes a dropped source folder. Nothing shows until a folder is over it.
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

                Text(viewModel.importingETA)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                if let currentFile = viewModel.importingCurrentFileText {
                    Text(currentFile)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
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
                status: viewModel.resultRouteStatus
            )

            completionSummary

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

    /// The main action is the check of what arrived. Without new folders to open,
    /// the next card becomes the main action.
    private var completionPrimaryAction: ResultAction {
        if viewModel.canOpenNewFinalMediaDirectories {
            return ResultAction(title: "Open New Folders in Finder", action: viewModel.openNewFinalMediaDirectories)
        }
        return importAnotherCardAction
    }

    private var completionSecondaryActions: [ResultAction] {
        var actions = [
            ResultAction(title: "View Receipt", isEnabled: viewModel.canOpenReceipt, action: viewModel.openReceipt),
            ResultAction(title: "Open Source", isEnabled: viewModel.canOpenSource, action: viewModel.openSource),
        ]
        if viewModel.canOpenNewFinalMediaDirectories {
            actions.append(ResultAction(title: "Import Another Card", action: viewModel.importAnotherCard))
        }
        return actions
    }

    private var importAnotherCardAction: ResultAction {
        ResultAction(title: "Import Another Card", action: viewModel.importAnotherCard)
    }

    /// The headline and sub-headline say what happened. The grid shows the evidence.
    /// The Film Mode line and the RAW notice sit together, so they read as one statement.
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

            Text(viewModel.completionReceiptText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Surface())
    }

    /// Four tiles in a row. One grid keeps all tiles on the same left edges.
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
                status: viewModel.resultRouteStatus
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
