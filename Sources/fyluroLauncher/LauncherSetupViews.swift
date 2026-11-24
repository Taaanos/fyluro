import FyluroCore
import SwiftUI

struct LauncherSetupRoutePanel: View {
    @ObservedObject var viewModel: LauncherViewModel

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                horizontalRoute

                if let routeError = viewModel.setupRouteErrorText {
                    NoticeBanner(tone: .error, text: routeError)
                }

                if let spaceWarningText = viewModel.destinationSpaceWarningText {
                    NoticeBanner(
                        tone: viewModel.destinationSpaceWarningTone,
                        title: viewModel.destinationSpaceWarningTitle,
                        text: spaceWarningText
                    ) {
                        if viewModel.isDestinationSpaceBlocking {
                            Button("Import Anyway", action: viewModel.acceptDestinationSpaceOverride)
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .padding(.top, 2)
                        }
                    }
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var horizontalRoute: some View {
        HStack(alignment: .center, spacing: 12) {
            sourceEndpoint
            routeArrow(symbolName: "arrow.right")
            destinationEndpoint
        }
    }

    var sourceButtonTitle: String {
        viewModel.sourcePath.isEmpty ? "Choose…" : "Change…"
    }

    var destinationButtonTitle: String {
        viewModel.destinationPath.isEmpty ? "Choose…" : "Change…"
    }

    private var sourceEndpoint: some View {
        LauncherSetupEndpoint(
            systemImage: "externaldrive",
            title: "Source",
            name: viewModel.sourcePath.isEmpty ? "Choose source" : viewModel.importSourceDisplayName,
            path: viewModel.sourcePath.isEmpty ? "No folder selected" : viewModel.importSourceDisplayPath,
            buttonTitle: sourceButtonTitle,
            isEnabled: !viewModel.isRunning,
            action: viewModel.pickSourcePath
        )
    }

    private var destinationEndpoint: some View {
        LauncherSetupEndpoint(
            systemImage: "folder",
            title: "Destination",
            name: viewModel.destinationPath.isEmpty ? "Choose destination" : viewModel.importDestinationDisplayName,
            path: viewModel.destinationPath.isEmpty ? "No folder selected" : viewModel.importDestinationDisplayPath,
            detail: viewModel.destinationFreeSpaceRowText,
            buttonTitle: destinationButtonTitle,
            isEnabled: !viewModel.isRunning,
            action: viewModel.pickDestinationPath
        )
    }

    private func routeArrow(symbolName: String) -> some View {
        Image(systemName: symbolName)
            .font(.system(size: 28, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(minWidth: 56)
            .accessibilityHidden(true)
    }
}

struct LauncherSetupEndpoint: View {
    let systemImage: String
    let title: String
    let name: String
    let path: String
    var detail: String? = nil
    let buttonTitle: String
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LauncherImportRouteEndpoint(
                title: title,
                systemImage: systemImage,
                name: name,
                path: path
            )

            HStack(alignment: .center, spacing: 8) {
                Button(buttonTitle, action: action)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .fixedSize()
                    .disabled(!isEnabled)

                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .padding(.leading, 44)
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
    }
}

struct LauncherSourceInventoryPanel: View {
    @ObservedObject var viewModel: LauncherViewModel
    @ObservedObject var cameraCatalogStore: LauncherCameraCatalogStore
    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                if viewModel.setupEmptySourceMessage == nil {
                    HStack(alignment: .center, spacing: 8) {
                        Image(systemName: "viewfinder")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)

                        Text("Scan Preview")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)

                        Spacer(minLength: 12)

                        if viewModel.isSourceScanning {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
                }

                inventoryContent
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var inventoryContent: some View {
        if let summary = viewModel.setupInventory {
            VStack(alignment: .leading, spacing: 12) {
                if viewModel.setupEmptySourceMessage != nil {
                    emptyMediaView

                    if let errorText = summary.scanErrorText {
                        NoticeBanner(tone: .error, text: errorText)
                    }

                    if let warningText = summary.scanWarningText {
                        NoticeBanner(tone: .attention, text: warningText)
                    }
                } else {
                    statGrid(summary)

                    if let errorText = summary.scanErrorText {
                        NoticeBanner(tone: .error, text: errorText)
                    }

                    if let warningText = summary.scanWarningText {
                        NoticeBanner(tone: .attention, text: warningText)
                    }

                    if let unsortedWarning = summary.unsortedWarningText {
                        NoticeBanner(tone: .attention, text: unsortedWarning)
                    }

                    if !viewModel.setupInventoryCameraEntries.isEmpty {
                        Divider()
                        cameraList
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if viewModel.isSourceScanFailed {
            NoticeBanner(tone: .error, text: viewModel.setupInventoryPlaceholderText)
        } else {
            Text(viewModel.setupInventoryPlaceholderText)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var emptyMediaView: some View {
        if #available(macOS 14.0, *) {
            ContentUnavailableView(
                "No Supported Media Found",
                systemImage: "photo.on.rectangle.angled",
                description: Text("This folder does not contain photos, videos, or audio files that \(AppBrand.name) can import.")
            )
            .frame(maxWidth: .infinity)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 28, weight: .regular))
                    .foregroundStyle(.secondary)
                Text("No Supported Media Found")
                    .font(.headline)
                Text("This folder does not contain photos, videos, or audio files that \(AppBrand.name) can import.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
        }
    }

    private func statGrid(_ summary: LauncherSourceScopeSummary) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .top, spacing: 10) {
                    StatItem(title: "Photos", value: "\(summary.photoCount)")
                    StatItem(title: "Videos", value: "\(summary.videoCount)")
                    if summary.audioCount > 0 {
                        StatItem(title: "Audio", value: "\(summary.audioCount)")
                    }
                    StatItem(title: "Cameras", value: "\(summary.detectedCameraCount)")
                    StatItem(title: "Size", value: viewModel.setupInventorySizeText)
                }

                if let sidecarNote = viewModel.setupInventorySidecarNoteText {
                    Text(sidecarNote)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let dateRangeText = viewModel.setupInventoryCaptureDateRangeText {
                StatItem(title: "Dates", value: dateRangeText)
            }
        }
    }

    private var cameraList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Camera Inventory")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            // A ScrollView always takes its full height. So a short list is a plain stack,
            // and only a long list scrolls inside a fixed height.
            if viewModel.setupInventoryCameraEntries.count > LauncherWindowMetrics.maxVisibleCameraRows {
                // The scrollbar draws over the content. Space on the right keeps it off the counts.
                ScrollView(.vertical) { cameraRows.padding(.trailing, 14) }
                    .frame(height: LauncherWindowMetrics.cameraInventoryMaxHeight)
            } else {
                cameraRows
            }
        }
    }

    private var cameraRows: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(viewModel.setupInventoryCameraEntries) { entry in
                let row = LauncherCameraInventoryRowPresentation.make(
                    for: entry,
                    catalogStore: cameraCatalogStore
                )
                HStack(spacing: 12) {
                    rowLabel(for: row)
                        .font(.subheadline)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer()
                    Text("\(entry.fileCount)")
                        .font(.subheadline.weight(.medium))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func rowLabel(for row: LauncherCameraInventoryRowPresentation) -> Text {
        if let folderSuffix = row.folderSuffix {
            return Text(row.primary) + Text(" (\(folderSuffix))").foregroundColor(.secondary)
        }
        return Text(row.primary)
    }
}

struct LauncherCameraInventoryRowPresentation: Equatable {
    let primary: String
    let folderSuffix: String?

    /// Shows the raw model code from metadata when the scan folder matches either
    /// the active catalog folder or the normalized model code itself. A label saved
    /// or removed after the scan does not rewrite an old scan's row until rescan.
    @MainActor
    static func make(
        for entry: LauncherSourceCameraSummary,
        catalogStore: LauncherCameraCatalogStore
    ) -> LauncherCameraInventoryRowPresentation {
        guard let code = entry.rawModelCode else {
            return LauncherCameraInventoryRowPresentation(primary: entry.displayLabel, folderSuffix: nil)
        }
        if let name = catalogStore.name(forCode: code),
           let folder = catalogStore.folderLabel(forName: name),
           folder == entry.label {
            return LauncherCameraInventoryRowPresentation(primary: code, folderSuffix: folder)
        }
        if CameraLabeler.folderLabel(forCatalogName: code) == entry.label {
            return LauncherCameraInventoryRowPresentation(primary: code, folderSuffix: nil)
        }
        return LauncherCameraInventoryRowPresentation(primary: entry.displayLabel, folderSuffix: nil)
    }
}

struct LauncherEmptySourcePanel: View {
    var body: some View {
        GroupBox {
            Group {
                if #available(macOS 14.0, *) {
                    ContentUnavailableView(
                        "No Source Selected",
                        systemImage: "sdcard",
                        description: Text("Insert a memory card, drag a folder here, or choose a source to preview files.")
                    )
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "sdcard")
                            .font(.system(size: 28, weight: .regular))
                            .foregroundStyle(.secondary)
                        Text("No Source Selected")
                            .font(.headline)
                        Text("Insert a memory card, drag a folder here, or choose a source to preview files.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity)
        }
    }
}
