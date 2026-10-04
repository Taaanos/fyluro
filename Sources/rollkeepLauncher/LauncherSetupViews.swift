import RollKeepCore
import SwiftUI
import UniformTypeIdentifiers

struct LauncherPanelStyle {
    let fillOpacity: Double
    let strokeOpacity: Double
    let iconFillOpacity: Double

    static let source = LauncherPanelStyle(fillOpacity: 0.06, strokeOpacity: 0.16, iconFillOpacity: 0.12)
    static let destination = LauncherPanelStyle(fillOpacity: 0.05, strokeOpacity: 0.14, iconFillOpacity: 0.1)
    static let scan = LauncherPanelStyle(fillOpacity: 0.045, strokeOpacity: 0.12, iconFillOpacity: 0.09)

    var accent: Color { LauncherTone.info.color }
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
    var onDropURLs: (([URL]) -> Void)?

    @State private var isDropTargeted = false

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
        .background(Surface(style: style))
        .overlay(
            RoundedRectangle(cornerRadius: LauncherRadius.card, style: .continuous)
                .stroke(style.accent.opacity(isDropTargeted && isEnabled ? 0.7 : 0), lineWidth: 2)
        )
        .animation(.easeOut(duration: 0.12), value: isDropTargeted)
        .onDrop(of: [.fileURL], isTargeted: dropTargetedBinding) { providers in
            handleDrop(providers)
        }
    }

    private var dropTargetedBinding: Binding<Bool> {
        Binding(
            get: { isDropTargeted },
            set: { isDropTargeted = isEnabled && $0 }
        )
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard isEnabled, let onDropURLs, let provider = providers.first,
              provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) else {
            return false
        }

        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
            let url: URL?
            switch item {
            case let data as Data:
                url = URL(dataRepresentation: data, relativeTo: nil)
            case let directURL as URL:
                url = directURL
            default:
                url = nil
            }

            guard let url else {
                return
            }

            Task { @MainActor in
                onDropURLs([url])
            }
        }

        return true
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
        .background(Surface(style: style))
    }

    @ViewBuilder
    private var inventoryContent: some View {
        if let summary = viewModel.setupInventory {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    StatItem(title: "Photos", value: "\(summary.photoCount)")
                    StatItem(title: "Videos", value: "\(summary.videoCount)")
                    if summary.audioCount > 0 {
                        StatItem(title: "Audio", value: "\(summary.audioCount)")
                    }
                    StatItem(title: "Cameras", value: "\(summary.detectedCameraCount)")
                    StatItem(title: "Size", value: viewModel.setupInventorySizeText)
                }

                if let dateRangeText = viewModel.setupInventoryCaptureDateRangeText {
                    StatItem(title: "Dates", value: dateRangeText)
                }

                if let spaceRowText = viewModel.destinationFreeSpaceRowText {
                    StatItem(title: "Free Space", value: spaceRowText)
                }

                if let errorText = summary.scanErrorText {
                    NoticeBanner(tone: .error, text: errorText)
                }

                if let warningText = summary.scanWarningText {
                    NoticeBanner(tone: .attention, text: warningText)
                }

                if let unsortedWarning = summary.unsortedWarningText {
                    NoticeBanner(tone: .attention, text: unsortedWarning)
                }

                if let spaceWarningText = viewModel.destinationSpaceWarningText {
                    NoticeBanner(tone: .error, text: spaceWarningText)
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
                        .frame(height: LauncherWindowMetrics.cameraInventoryMaxHeight)
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

        return "Scan details appear here once \(AppBrand.name) can inspect the selected source."
    }
}
