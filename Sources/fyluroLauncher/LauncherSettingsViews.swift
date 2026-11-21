import FyluroCore
import SwiftUI

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

struct LauncherSettingsView: View {
    @ObservedObject var pathSchemeSettingsStore: LauncherPathSchemeSettingsStore

    var body: some View {
        Form {
            Section("Folder Layout") {
                let example = exampleDateComponents
                Picker("Date folders", selection: draftChronologicalLayoutBinding) {
                    Text("Year, then year and month (\(example.year)/\(example.year)\(example.month))")
                        .tag(PathChronologicalLayout.yearYearMonthCompact)
                    Text("Year, then month (\(example.year)/\(example.month))")
                        .tag(PathChronologicalLayout.yearMonthNested)
                    Text("Year only (\(example.year))")
                        .tag(PathChronologicalLayout.yearOnly)
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

    private var actionBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack {
                Button("Reset to Default", action: pathSchemeSettingsStore.resetDraftToDefault)
                Spacer()
                Button("Apply", action: pathSchemeSettingsStore.applyDraft)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!pathSchemeSettingsStore.hasPendingChanges)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .background(.bar)
    }

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

    private var exampleDateComponents: (year: String, month: String) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .autoupdatingCurrent
        let components = calendar.dateComponents([.year, .month], from: Date())
        let year = components.year ?? 2026
        let month = components.month ?? 1
        return (String(format: "%04d", year), String(format: "%02d", month))
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
