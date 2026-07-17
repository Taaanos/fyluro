import AppKit
import SwiftUI

struct LauncherContentView: View {
    @StateObject private var viewModel: LauncherViewModel
    @State private var configuredWindowID: ObjectIdentifier?
    @State private var measuredContentHeight: CGFloat?
    @State private var isFilmModeSheetPresented = false

    init(pathSchemeSettingsStore: LauncherPathSchemeSettingsStore? = nil) {
        let store = pathSchemeSettingsStore ?? LauncherPathSchemeSettingsStore()
        _viewModel = StateObject(wrappedValue: LauncherViewModel(pathSchemeSettingsStore: store))
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
        .background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: LauncherContentHeightPreferenceKey.self,
                    value: proxy.size.height
                )
            }
        )
        .background(
            LauncherWindowAccessor { window in
                configureWindow(window)
            }
        )
        .onPreferenceChange(LauncherContentHeightPreferenceKey.self) { height in
            let roundedHeight = ceil(height)
            guard roundedHeight > 0 else {
                return
            }

            let currentHeight = measuredContentHeight ?? 0
            guard abs(currentHeight - roundedHeight) > 0.5 else {
                return
            }

            measuredContentHeight = roundedHeight
        }
        .task {
            viewModel.prepareDefaultsOnLaunch()
        }
    }

    private var setupSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            LauncherSelectionCard(
                systemImage: "externaldrive",
                style: .source,
                title: "Source",
                path: viewModel.sourcePath,
                placeholder: "Choose source",
                buttonTitle: viewModel.sourcePath.isEmpty ? "Choose" : "Change",
                isEnabled: !viewModel.isRunning,
                action: viewModel.pickSourcePath,
                onDropURLs: viewModel.acceptDroppedSource
            )

            LauncherSelectionCard(
                systemImage: "folder",
                style: .destination,
                title: "Destination",
                path: viewModel.destinationPath,
                placeholder: "Choose destination",
                buttonTitle: viewModel.destinationPath.isEmpty ? "Choose" : "Change",
                isEnabled: !viewModel.isRunning,
                action: viewModel.pickDestinationPath,
                onDropURLs: viewModel.acceptDroppedDestination
            )

            LauncherSourceInventoryPanel(viewModel: viewModel, style: .scan)

            LauncherFilmModeToggleRow(viewModel: viewModel, isFilmModeSheetPresented: $isFilmModeSheetPresented)

            startImportButton

            if viewModel.isDestinationSpaceBlocking {
                Button("Import Anyway", action: viewModel.acceptDestinationSpaceOverride)
                    .buttonStyle(.plain)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }

            if viewModel.uiState != .ready {
                Text(viewModel.statusMessage)
                    .font(.footnote)
                    .foregroundStyle(viewModel.statusColor)
            }
        }
    }

    @ViewBuilder
    private var startImportButton: some View {
        if viewModel.isImportReady {
            Button(action: viewModel.startIngest) {
                Text("Import")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .frame(maxWidth: .infinity)
        } else {
            Button(action: viewModel.startIngest) {
                Text("Import")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .frame(maxWidth: .infinity)
            .disabled(true)
        }
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
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.orange)
                            .padding(.top, 1)

                        VStack(alignment: .leading, spacing: 4) {
                            Text(viewModel.completionWarningTitle)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.primary)
                                .textSelection(.enabled)

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
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.orange.opacity(0.1))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.orange.opacity(0.35), lineWidth: 0.8)
                )
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

    private var preferredContentHeight: CGFloat {
        LauncherWindowMetrics.preferredContentHeight(
            for: viewModel.uiState,
            measuredHeight: measuredContentHeight
        )
    }

    private func configureWindow(_ window: NSWindow) {
        let id = ObjectIdentifier(window)
        if configuredWindowID != id {
            configuredWindowID = id
        }

        let minimumContentSize = NSSize(
            width: LauncherWindowMetrics.minWidth,
            height: preferredContentHeight
        )
        if window.contentMinSize != minimumContentSize {
            window.contentMinSize = minimumContentSize
        }

        let targetContentSize = NSSize(
            width: LauncherWindowMetrics.idealWidth,
            height: preferredContentHeight
        )
        let currentContentSize = window.contentLayoutRect.size
        let sizeDelta = abs(currentContentSize.width - targetContentSize.width)
            + abs(currentContentSize.height - targetContentSize.height)
        guard sizeDelta > 0.5 else {
            return
        }

        window.setContentSize(targetContentSize)
    }
}

private struct LauncherWindowAccessor: NSViewRepresentable {
    let onResolveWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { [weak view] in
            guard let window = view?.window else {
                return
            }
            onResolveWindow(window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let window = nsView.window else {
                return
            }
            onResolveWindow(window)
        }
    }
}

private struct LauncherContentHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
