import RollKeepCore
import SwiftUI

/// Apple's Settings pattern: toolbar tabs, each pane self-contained. The
/// Catalogue pane keeps its Apply/Reset bar (path scheme only); Camera Labels
/// saves every edit immediately, so nothing in it waits on Apply.
struct LauncherSettingsRootView: View {
    @ObservedObject var pathSchemeSettingsStore: LauncherPathSchemeSettingsStore
    @ObservedObject var cameraCatalogStore: LauncherCameraCatalogStore

    var body: some View {
        TabView {
            LauncherSettingsView(pathSchemeSettingsStore: pathSchemeSettingsStore)
                .tabItem { Label(Self.paddedTabTitle("Catalogue"), systemImage: "folder") }

            LauncherCameraLabelsSettingsView(store: cameraCatalogStore)
                .tabItem { Label(Self.paddedTabTitle("Camera Labels"), systemImage: "camera") }
        }
    }

    /// The native toolbar tab style sizes each highlight to its label with no
    /// inner padding, so the hover/selected pill hugs the text. En spaces give
    /// the label a little breathing room without leaving the native style.
    private static func paddedTabTitle(_ title: String) -> String {
        "\u{2002}\(title)\u{2002}"
    }
}

struct LauncherSettingsView: View {
    @ObservedObject var pathSchemeSettingsStore: LauncherPathSchemeSettingsStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 14) {
                LauncherSettingsCard(
                    title: "Catalogue Scheme",
                    subtitle: "Configure date layout and optional path properties together."
                ) {
                    VStack(alignment: .leading, spacing: 12) {
                        Picker("Chronological layout", selection: draftChronologicalLayoutBinding) {
                            Text("YYYY/YYYYMM").tag(PathChronologicalLayout.yearYearMonthCompact)
                            Text("YYYY/MM").tag(PathChronologicalLayout.yearMonthNested)
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(maxWidth: 220, alignment: .leading)

                        Divider()

                        Toggle("Group by camera", isOn: draftIncludeCameraBinding)
                        Toggle("Split photos into RAW / Non-RAW", isOn: draftSplitPhotoCompressionBinding)
                    }
                }

                LauncherSettingsCard(
                    title: "Render Paths",
                    subtitle: "Preview how files will be placed before applying."
                ) {
                    VStack(alignment: .leading, spacing: 10) {
                        LauncherSettingsPreviewPathCard(
                            title: "Sample photo",
                            systemImage: "photo",
                            path: pathSchemeSettingsStore.draftPhotoPreviewPath
                        )
                        LauncherSettingsPreviewPathCard(
                            title: "Sample video",
                            systemImage: "video",
                            path: pathSchemeSettingsStore.draftVideoPreviewPath
                        )
                        LauncherSettingsPreviewPathCard(
                            title: "Sample audio",
                            systemImage: "waveform",
                            path: pathSchemeSettingsStore.draftAudioPreviewPath
                        )
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 0)

            HStack {
                Button("Reset to Default", action: pathSchemeSettingsStore.resetDraftToDefault)
                Spacer()
                if let inlineWarningTooltip {
                    LauncherSettingsHoverWarningIndicator(message: inlineWarningTooltip)
                        .padding(.trailing, 2)
                        .padding(.top, 1)
                }
                Button("Apply", action: applyAndDismiss)
                    .buttonStyle(.borderedProminent)
                    .disabled(!pathSchemeSettingsStore.hasPendingChanges)
            }
        }
        .padding(18)
        .frame(
            width: LauncherSettingsWindowMetrics.width,
            height: LauncherSettingsWindowMetrics.height,
            alignment: .topLeading
        )
    }

    private func applyAndDismiss() {
        pathSchemeSettingsStore.applyDraft()
        dismiss()
    }

    private var draftChronologicalLayoutBinding: Binding<PathChronologicalLayout> {
        Binding(
            get: { pathSchemeSettingsStore.draftConfiguration.chronologicalLayout },
            set: { newValue in
                var updated = pathSchemeSettingsStore.draftConfiguration
                updated.chronologicalLayout = newValue
                pathSchemeSettingsStore.draftConfiguration = updated
            }
        )
    }

    private var draftIncludeCameraBinding: Binding<Bool> {
        Binding(
            get: { pathSchemeSettingsStore.draftConfiguration.includeCameraFolder },
            set: { newValue in
                var updated = pathSchemeSettingsStore.draftConfiguration
                updated.includeCameraFolder = newValue
                pathSchemeSettingsStore.draftConfiguration = updated
            }
        )
    }

    private var draftSplitPhotoCompressionBinding: Binding<Bool> {
        Binding(
            get: { pathSchemeSettingsStore.draftConfiguration.splitPhotoCompression },
            set: { newValue in
                var updated = pathSchemeSettingsStore.draftConfiguration
                updated.splitPhotoCompression = newValue
                pathSchemeSettingsStore.draftConfiguration = updated
            }
        )
    }

    private var inlineWarningTooltip: String? {
        let warnings = pathSchemeSettingsStore.pendingWarningMessages
        guard !warnings.isEmpty else {
            return nil
        }
        return warnings.joined(separator: "\n")
    }
}

struct LauncherSettingsHoverWarningIndicator: View {
    let message: String
    @State private var isTooltipVisible = false
    @State private var isHoveringIcon = false
    @State private var isHoveringTooltip = false
    @State private var pendingShowTask: DispatchWorkItem?
    @State private var pendingHideTask: DispatchWorkItem?

    private let hoverDelay: TimeInterval = 0.3
    private let hoverExitGraceDelay: TimeInterval = 0.56
    private let hoverTargetSize: CGFloat = 28

    var body: some View {
        Image(systemName: "exclamationmark.triangle.fill")
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(.orange)
            .frame(width: hoverTargetSize, height: hoverTargetSize)
            .contentShape(Rectangle())
            .popover(isPresented: $isTooltipVisible, attachmentAnchor: .point(.top), arrowEdge: .bottom) {
                tooltipBody
            }
            .onHover(perform: handleIconHoverChanged)
            .onDisappear {
                isHoveringIcon = false
                isHoveringTooltip = false
                pendingShowTask?.cancel()
                pendingHideTask?.cancel()
            }
            .accessibilityLabel("Settings warnings available")
    }

    private var tooltipBody: some View {
        Text(message)
            .font(.caption)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .lineSpacing(1.5)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(width: 320, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color.orange.opacity(0.35), lineWidth: 0.8)
                    )
            )
            .shadow(color: Color.black.opacity(0.18), radius: 8, x: 0, y: 2)
            .contentShape(Rectangle())
            .onHover(perform: handleTooltipHoverChanged)
    }

    private var isHoveringActiveRegion: Bool {
        isHoveringIcon || isHoveringTooltip
    }

    private func handleIconHoverChanged(_ isHovering: Bool) {
        isHoveringIcon = isHovering
        updateTooltipVisibilityForHoverState()
    }

    private func handleTooltipHoverChanged(_ isHovering: Bool) {
        isHoveringTooltip = isHovering
        updateTooltipVisibilityForHoverState()
    }

    private func updateTooltipVisibilityForHoverState() {
        if isHoveringActiveRegion {
            pendingHideTask?.cancel()
            pendingHideTask = nil

            if isTooltipVisible {
                return
            }
            if pendingShowTask != nil {
                return
            }

            let task = DispatchWorkItem {
                pendingShowTask = nil
                guard isHoveringActiveRegion else {
                    return
                }
                isTooltipVisible = true
            }
            pendingShowTask = task
            DispatchQueue.main.asyncAfter(deadline: .now() + hoverDelay, execute: task)
        } else {
            pendingShowTask?.cancel()
            pendingShowTask = nil

            guard isTooltipVisible else {
                return
            }

            let task = DispatchWorkItem {
                pendingHideTask = nil
                guard !isHoveringActiveRegion else {
                    return
                }
                isHoveringTooltip = false
                isTooltipVisible = false
            }
            pendingHideTask = task
            DispatchQueue.main.asyncAfter(deadline: .now() + hoverExitGraceDelay, execute: task)
        }
    }
}

struct LauncherSettingsCard<Content: View>: View {
    let title: String
    let subtitle: String
    let accent: Color
    @ViewBuilder let content: () -> Content

    init(
        title: String,
        subtitle: String,
        accent: Color = .blue,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.accent = accent
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)

            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(accent.opacity(0.045))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(accent.opacity(0.18), lineWidth: 0.8)
                )
        )
    }
}

struct LauncherSettingsPreviewPathCard: View {
    let title: String
    let systemImage: String
    let path: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            ScrollView(.horizontal, showsIndicators: true) {
                Text(path)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 9)
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(nsColor: .windowBackgroundColor).opacity(0.6))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.secondary.opacity(0.25), lineWidth: 0.7)
            )
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.secondary.opacity(0.14), lineWidth: 0.7)
        )
    }
}
