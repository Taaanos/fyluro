import RollKeepCore
import SwiftUI

/// Apple's Settings pattern: toolbar tabs, each pane self-contained. The
/// Library pane keeps its Apply/Reset bar (path scheme only); Camera Labels
/// and Transfers save every edit immediately, so nothing in them waits on Apply.
struct LauncherSettingsRootView: View {
    @ObservedObject var pathSchemeSettingsStore: LauncherPathSchemeSettingsStore
    @ObservedObject var cameraCatalogStore: LauncherCameraCatalogStore
    @ObservedObject var transferSettingsStore: LauncherTransferSettingsStore

    var body: some View {
        TabView {
            LauncherSettingsView(pathSchemeSettingsStore: pathSchemeSettingsStore)
                .tabItem { Label("Library", systemImage: "folder") }

            LauncherCameraLabelsSettingsView(store: cameraCatalogStore)
                .tabItem { Label("Camera Labels", systemImage: "camera") }

            LauncherTransferSettingsView(store: transferSettingsStore)
                .tabItem { Label("Transfers", systemImage: "arrow.left.arrow.right") }
        }
    }
}

/// The Library pane: where imported files go. The user edits a draft, sees the preview change,
/// and presses Apply. The import reads the saved scheme once, at the start of a run (ROL-6 I-10),
/// so a change never affects a running import.
struct LauncherSettingsView: View {
    @ObservedObject var pathSchemeSettingsStore: LauncherPathSchemeSettingsStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section("Folder Layout") {
                Picker("Date folders", selection: draftChronologicalLayoutBinding) {
                    Text("Year, then year and month (2026/202603)").tag(PathChronologicalLayout.yearYearMonthCompact)
                    Text("Year, then month (2026/03)").tag(PathChronologicalLayout.yearMonthNested)
                }
                .pickerStyle(.menu)

                Toggle("Group by camera", isOn: draftIncludeCameraBinding)
                Toggle("Split photos into RAW / Non-RAW", isOn: draftSplitPhotoCompressionBinding)
            }

            Section {
                previewRow("Photo", systemImage: "photo", path: pathSchemeSettingsStore.draftPhotoPreviewPath)
                previewRow("Video", systemImage: "video", path: pathSchemeSettingsStore.draftVideoPreviewPath)
                previewRow("Audio", systemImage: "waveform", path: pathSchemeSettingsStore.draftAudioPreviewPath)
            } header: {
                Text("Preview")
            } footer: {
                SettingsFootnote("Sample paths for the layout above. Apply saves the layout for the next import.")
            }

            if !pathSchemeSettingsStore.pendingWarningMessages.isEmpty {
                Section {
                    NoticeBanner(
                        tone: .attention,
                        text: pathSchemeSettingsStore.pendingWarningMessages.joined(separator: "\n"),
                        emphasizedText: true
                    )
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }
            }
        }
        .formStyle(.grouped)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            actionBar
        }
        .frame(width: LauncherSettingsWindowMetrics.width, height: paneHeight)
    }

    /// A grouped Form has no height of its own on macOS, so the pane needs one.
    private var paneHeight: CGFloat {
        pathSchemeSettingsStore.pendingWarningMessages.isEmpty ? 470 : 570
    }

    /// Reset and Apply are actions, not settings, so they sit in a bar under the Form, not in a group.
    private var actionBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack {
                Button("Reset to Default", action: pathSchemeSettingsStore.resetDraftToDefault)
                Spacer()
                Button("Apply", action: applyAndDismiss)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!pathSchemeSettingsStore.hasPendingChanges)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .background(.bar)
    }

    /// Label above path in every row, so the three rows have the same shape and the path
    /// starts at the same x position. A long path never changes the row layout.
    /// The sample path is not selectable: nobody needs to copy it.
    private func previewRow(_ title: String, systemImage: String, path: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: systemImage)
            Text(path)
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
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
}

/// The note under a settings group. The style is set here, not left to the Form footer,
/// because the footer rendered with trailing line alignment and body-size primary text.
struct SettingsFootnote: View {
    private let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
