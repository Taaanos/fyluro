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
        .frame(
            minWidth: LauncherWindowMetrics.minWidth,
            idealWidth: LauncherWindowMetrics.idealWidth,
            alignment: .topLeading
        )
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
            viewModel.scheduleSourceScanIfNeeded()
        case .running, .success, .failure:
            break
        }
    }

    private var setupSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            LauncherSetupRoutePanel(viewModel: viewModel)

            LauncherSourceInventoryPanel(viewModel: viewModel)

            LauncherFilmModeToggleRow(viewModel: viewModel, isFilmModeSheetPresented: $isFilmModeSheetPresented)

            startImportButton

            if let notice = viewModel.setupStatusNoticeText {
                NoticeBanner(tone: .attention, text: notice, emphasizedText: true)
            }
        }
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
                isActive: viewModel.isRunning
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

            HStack(spacing: 12) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(viewModel.hasRecordedErrors ? .orange : .green)
                VStack(alignment: .leading, spacing: 4) {
                    Text(viewModel.completionItemsText)
                        .font(.headline)
                    Text(viewModel.completionOutcomeText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if let durationText = viewModel.completionDurationText {
                        Text(durationText)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Text(viewModel.completionReceiptText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )

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

            if let noticeText = viewModel.filmModeRawSkipNoticeText {
                NoticeBanner(tone: .attention, text: noticeText)
            }

            if viewModel.canOpenNewFinalMediaDirectories {
                Button("Open New Folders in Finder", action: viewModel.openNewFinalMediaDirectories)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)
            }

            Button("Open Source", action: viewModel.openSource)
                .buttonStyle(.bordered)
                .frame(maxWidth: .infinity)
                .disabled(!viewModel.canOpenSource)

            Button("View Receipt", action: viewModel.openReceipt)
                .buttonStyle(.bordered)
                .frame(maxWidth: .infinity)
                .disabled(!viewModel.canOpenReceipt)

            Button("Import Another Card", action: viewModel.importAnotherCard)
                .buttonStyle(.bordered)
                .frame(maxWidth: .infinity)
        }
    }

    private var failureSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(viewModel.failureTitle)
                .font(.title3.weight(.semibold))

            Text(viewModel.failureMessage)
                .font(.body)
                .foregroundStyle(.primary)

            HStack(spacing: 10) {
                Button("View Receipt", action: viewModel.openReceipt)
                    .buttonStyle(.bordered)
                    .disabled(!viewModel.canOpenReceipt)

                Button("Open Destination", action: viewModel.openDestination)
                    .buttonStyle(.bordered)
                    .disabled(!viewModel.canOpenDestination)

                Spacer()

                Button("Import Another Card", action: viewModel.importAnotherCard)
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}
