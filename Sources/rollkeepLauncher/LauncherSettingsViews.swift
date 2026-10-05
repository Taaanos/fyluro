import RollKeepCore
import SwiftUI

/// Apple's Settings pattern: toolbar tabs, each pane self-contained. The
/// Library pane keeps its Apply/Reset bar (path scheme only); Camera Labels
/// saves every edit immediately, so nothing in it waits on Apply.
struct LauncherSettingsRootView: View {
    @ObservedObject var pathSchemeSettingsStore: LauncherPathSchemeSettingsStore
    @ObservedObject var cameraCatalogStore: LauncherCameraCatalogStore

    var body: some View {
        TabView {
            LauncherSettingsView(pathSchemeSettingsStore: pathSchemeSettingsStore)
                .tabItem { Label("Library", systemImage: "folder") }

            LauncherCameraLabelsSettingsView(store: cameraCatalogStore)
                .tabItem { Label("Camera Labels", systemImage: "camera") }
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
                    Text("YYYY/YYYYMM").tag(PathChronologicalLayout.yearYearMonthCompact)
                    Text("YYYY/MM").tag(PathChronologicalLayout.yearMonthNested)
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
                Text("Sample paths for the layout above. Apply saves the layout for the next import.")
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

            Section {
                HStack {
                    Button("Reset to Default", action: pathSchemeSettingsStore.resetDraftToDefault)
                    Spacer()
                    Button("Apply", action: applyAndDismiss)
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!pathSchemeSettingsStore.hasPendingChanges)
                }
                .listRowBackground(Color.clear)
            }
        }
        .formStyle(.grouped)
        .frame(width: LauncherSettingsWindowMetrics.width, height: paneHeight)
    }

    /// A grouped Form has no height of its own on macOS, so the pane needs one.
    private var paneHeight: CGFloat {
        pathSchemeSettingsStore.pendingWarningMessages.isEmpty ? 470 : 570
    }

    private func previewRow(_ title: String, systemImage: String, path: String) -> some View {
        LabeledContent {
            ScrollView(.horizontal, showsIndicators: false) {
                Text(path)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .fixedSize()
            }
        } label: {
            Label(title, systemImage: systemImage)
        }
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
