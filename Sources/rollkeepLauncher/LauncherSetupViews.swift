import SwiftUI

struct LauncherPanelStyle {
    let fillOpacity: Double
    let strokeOpacity: Double
    let iconFillOpacity: Double

    static let source = LauncherPanelStyle(fillOpacity: 0.06, strokeOpacity: 0.16, iconFillOpacity: 0.12)
    static let destination = LauncherPanelStyle(fillOpacity: 0.05, strokeOpacity: 0.14, iconFillOpacity: 0.1)
    static let scan = LauncherPanelStyle(fillOpacity: 0.045, strokeOpacity: 0.12, iconFillOpacity: 0.09)

    var accent: Color { .blue }
}

struct LauncherPanelBackground: View {
    let style: LauncherPanelStyle

    var body: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(Color(nsColor: .controlBackgroundColor))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(style.accent.opacity(style.fillOpacity))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(style.accent.opacity(style.strokeOpacity), lineWidth: 0.8)
            )
            .shadow(color: Color.black.opacity(0.05), radius: 10, y: 2)
    }
}

struct LauncherSelectionCard: View {
    let systemImage: String
    let style: LauncherPanelStyle
    let title: String
    let path: String
    let placeholder: String
    let buttonTitle: String
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(style.accent.opacity(style.iconFillOpacity))

                Image(systemName: systemImage)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(style.accent)
            }
            .frame(width: 38, height: 38)

            VStack(alignment: .leading, spacing: 4) {
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
            }

            Spacer(minLength: 12)

            Button(buttonTitle, action: action)
                .buttonStyle(.bordered)
                .disabled(!isEnabled)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LauncherPanelBackground(style: style))
    }
}

struct LauncherSourceInventoryPanel: View {
    @ObservedObject var viewModel: LauncherViewModel
    let style: LauncherPanelStyle

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(style.accent.opacity(style.iconFillOpacity))

                    Image(systemName: "viewfinder")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(style.accent)
                }
                .frame(width: 38, height: 38)

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
        .background(LauncherPanelBackground(style: style))
    }

    @ViewBuilder
    private var inventoryContent: some View {
        if let summary = viewModel.setupInventory {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    LauncherSourceInventoryStat(title: "Photos", value: "\(summary.photoCount)")
                    LauncherSourceInventoryStat(title: "Videos", value: "\(summary.videoCount)")
                    LauncherSourceInventoryStat(title: "Cameras", value: "\(summary.detectedCameraCount)")
                    LauncherSourceInventoryStat(title: "Size", value: viewModel.setupInventorySizeText)
                }

                if let unsortedWarning = summary.unsortedWarningText {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.orange)
                            .padding(.top, 1)

                        Text(unsortedWarning)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
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

                if !viewModel.setupInventoryCameraEntries.isEmpty {
                    Divider()

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Camera Inventory")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)

                        ScrollView(.vertical, showsIndicators: viewModel.setupInventoryCameraEntries.count > LauncherWindowMetrics.maxVisibleCameraRows) {
                            LazyVStack(alignment: .leading, spacing: 8) {
                                ForEach(viewModel.setupInventoryCameraEntries) { entry in
                                    HStack(spacing: 12) {
                                        Text(entry.displayLabel)
                                            .font(.subheadline)
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
                        .frame(maxHeight: LauncherWindowMetrics.cameraInventoryMaxHeight)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text(inventoryPlaceholderText)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: LauncherWindowMetrics.emptyInventoryCardMinHeight, alignment: .topLeading)
        }
    }

    private var inventoryPlaceholderText: String {
        if viewModel.isSourceScanning {
            return viewModel.setupScopeSummaryText
        }

        if viewModel.sourcePath.isEmpty {
            return "Choose a source to preview photos, videos, cameras, and total size before import."
        }

        return "Scan details appear here once RollKeep can inspect the selected source."
    }
}

struct LauncherSourceInventoryStat: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.headline)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
