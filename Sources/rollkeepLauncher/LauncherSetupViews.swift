import RollKeepCore
import SwiftUI

/// The setup route: Source on top, Destination below, joined by a connector.
/// The whole window takes a dropped source folder (see the setup section). Free space sits under the destination,
/// because it describes the destination and not the source.
struct LauncherSetupRoutePanel: View {
    @ObservedObject var viewModel: LauncherViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            LauncherRouteRow(
                systemImage: "externaldrive",
                title: "Source",
                path: viewModel.sourcePath,
                placeholder: "Choose source",
                buttonTitle: viewModel.sourcePath.isEmpty ? "Choose" : "Change",
                isEnabled: !viewModel.isRunning,
                action: viewModel.pickSourcePath
            )

            connector

            LauncherRouteRow(
                systemImage: "folder",
                title: "Destination",
                path: viewModel.destinationPath,
                placeholder: "Choose destination",
                detail: viewModel.destinationFreeSpaceRowText,
                buttonTitle: viewModel.destinationPath.isEmpty ? "Choose" : "Change",
                isEnabled: !viewModel.isRunning,
                action: viewModel.pickDestinationPath
            )

            if let spaceWarningText = viewModel.destinationSpaceWarningText {
                NoticeBanner(tone: .error, text: spaceWarningText) {
                    if viewModel.isDestinationSpaceBlocking {
                        Button("Import Anyway", action: viewModel.acceptDestinationSpaceOverride)
                            .controlSize(.small)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.top, 4)
                .padding(.bottom, 8)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Surface())
    }

    /// An arrow under the center of the tile column. It shows the direction of the copy.
    private var connector: some View {
        Image(systemName: "arrow.down")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: 38)
            .padding(.leading, 8)
            .padding(.vertical, 2)
            .accessibilityHidden(true)
    }
}

/// One row of the route panel: tile, title, path or placeholder, optional detail line, and a button.
struct LauncherRouteRow: View {
    let systemImage: String
    let title: String
    let path: String
    let placeholder: String
    var detail: String?
    let buttonTitle: String
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            LauncherIconTile(systemImage: systemImage)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                if path.isEmpty {
                    Text(placeholder)
                        .font(.body)
                        .foregroundStyle(.secondary)
                } else {
                    Text(path)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 12)

            Button(buttonTitle, action: action)
                .buttonStyle(.bordered)
                .disabled(!isEnabled)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The panel shows nothing until a source is chosen. An empty panel adds no information.
struct LauncherSourceInventoryPanel: View {
    @ObservedObject var viewModel: LauncherViewModel
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                LauncherIconTile(systemImage: "viewfinder")

                Text("Scan Preview")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Spacer(minLength: 12)

                if viewModel.isSourceScanning {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            inventoryContent
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Surface())
    }

    @ViewBuilder
    private var inventoryContent: some View {
        if let summary = viewModel.setupInventory {
            VStack(alignment: .leading, spacing: 12) {
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
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text(inventoryPlaceholderText)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// One grid, so the counts and the date range share the same left edge.
    private func statGrid(_ summary: LauncherSourceScopeSummary) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 12) {
            GridRow {
                StatItem(title: "Photos", value: "\(summary.photoCount)")
                StatItem(title: "Videos", value: "\(summary.videoCount)")
                if summary.audioCount > 0 {
                    StatItem(title: "Audio", value: "\(summary.audioCount)")
                }
                StatItem(title: "Cameras", value: "\(summary.detectedCameraCount)")
                StatItem(title: "Size", value: viewModel.setupInventorySizeText)
            }

            if let dateRangeText = viewModel.setupInventoryCaptureDateRangeText {
                GridRow {
                    StatItem(title: "Dates", value: dateRangeText)
                        .gridCellColumns(summary.audioCount > 0 ? 5 : 4)
                }
            }
        }
    }

    /// Each row shows the folder name that the app will create, and how many files go in it.
    private var cameraList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Camera Inventory")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            // A ScrollView always takes its full height. So a short list is a plain stack,
            // and only a long list scrolls inside a fixed height.
            if viewModel.setupInventoryCameraEntries.count > LauncherWindowMetrics.maxVisibleCameraRows {
                ScrollView(.vertical) { cameraRows }
                    .frame(height: LauncherWindowMetrics.cameraInventoryMaxHeight)
            } else {
                cameraRows
            }
        }
    }

    private var cameraRows: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(viewModel.setupInventoryCameraEntries) { entry in
                HStack(spacing: 12) {
                    Text(entry.displayLabel)
                        .font(entry.isUnknown ? .subheadline : .system(.subheadline, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer()
                    Text("\(entry.fileCount)")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var inventoryPlaceholderText: String {
        if viewModel.isSourceScanning {
            return viewModel.setupScopeSummaryText
        }

        return "Scan details appear here once \(AppBrand.name) can inspect the selected source."
    }
}
