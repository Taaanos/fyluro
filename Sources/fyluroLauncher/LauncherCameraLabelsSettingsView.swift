import FyluroCore
import SwiftUI

struct LauncherCameraLabelsSettingsView: View {
    @ObservedObject var store: LauncherCameraCatalogStore

    private static let disabledPaneHeight: CGFloat = 230

    private var enabledBinding: Binding<Bool> {
        Binding(get: { store.isEnabled }, set: { store.setEnabled($0) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Name your cameras so library folders read “osmoaction6” instead of “ac006”.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 20)
                .padding(.top, 16)

            form
        }
        .frame(width: LauncherSettingsWindowMetrics.width, height: paneHeight)
        // A saved camera leaves the top list and joins the bottom list in one step.
        // An animation here makes the rows and the pane height jump, so there is none.
        .transaction { $0.animation = nil }
        .onAppear { store.reload() }
    }

    private var form: some View {
        Form {
            Section {
                Toggle("Use camera labels (experimental)", isOn: enabledBinding)
            } footer: {
                SettingsFootnote(store.isEnabled
                     ? "Imports name library folders with your labels. A label you change later puts new files in a new folder. Old folders stay as they are."
                     : "When off, library folders use the camera code from each file. This feature is experimental and may change.")
            }

            if store.isEnabled {
                labelEditorSections
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var labelEditorSections: some View {
        if store.loadWarning != nil || store.recoveryNotice != nil || store.saveError != nil {
            Section {
                if let warning = store.loadWarning {
                    NoticeBanner(tone: .attention, text: warning, emphasizedText: true)
                }
                if let notice = store.recoveryNotice {
                    NoticeBanner(tone: .info, text: notice, emphasizedText: true)
                }
                if let error = store.saveError {
                    NoticeBanner(tone: .error, text: error, emphasizedText: true)
                }
            }
        }

        Section {
            currentCardContent
        } header: {
            Text("On the Current Card")
        } footer: {
            SettingsFootnote("Cameras found on the scanned card that do not have a label yet.")
        }

        Section {
            yourLabelsContent
        } header: {
            Text("Your Labels")
        } footer: {
            SettingsFootnote("Saved as you type. Add a camera even if it is not on the card.")
        }
    }

    /// A grouped Form has no height of its own on macOS, so the pane needs one.
    /// It grows with the number of rows, up to a limit. After the limit the Form scrolls.
    private var paneHeight: CGFloat {
        guard store.isEnabled else { return Self.disabledPaneHeight }
        let rows = max(store.unmappedDetectedCameras.count, 1) + max(store.savedLabels.count, 1)
        let banners = [store.loadWarning, store.recoveryNotice, store.saveError].compactMap { $0 }.count
        let height = 390 + CGFloat(rows) * 31 + CGFloat(banners) * 60
        return min(height, LauncherSettingsWindowMetrics.maxPaneHeight)
    }

    @ViewBuilder
    private var currentCardContent: some View {
        let cameras = store.unmappedDetectedCameras
        if cameras.isEmpty {
            Text(store.detectedCameras.isEmpty
                 ? "Insert a card to see its cameras here."
                 : "Every camera on this card already has a label.")
                .foregroundStyle(.secondary)
        } else {
            Grid(alignment: .topLeading, horizontalSpacing: 10, verticalSpacing: 10) {
                ForEach(cameras) { camera in
                    LauncherDetectedCameraRow(store: store, camera: camera)
                }
            }
        }
    }

    private var yourLabelsContent: some View {
        Grid(alignment: .topLeading, horizontalSpacing: 10, verticalSpacing: 10) {
            GridRow {
                columnTitle("Camera Code")
                columnTitle("Name")
                columnTitle("Folder")
                Color.clear.frame(width: 0, height: 0)
            }

            let labels = store.savedLabels
            if labels.isEmpty {
                LauncherCameraLabelExampleRow()
            } else {
                ForEach(labels) { label in
                    LauncherSavedCameraLabelRow(store: store, label: label)
                }
            }

            Divider()
                .gridCellUnsizedAxes(.horizontal)
                .gridCellColumns(4)

            LauncherNewCameraLabelRow(store: store)
        }
    }

    private func columnTitle(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
    }
}

private enum LauncherCameraLabelsMetrics {
    static let codeColumnWidth: CGFloat = 160
    static let folderColumnWidth: CGFloat = 90
    static let trailingColumnWidth: CGFloat = 24
}

private struct LauncherCameraCodeText: View {
    let code: String

    var body: some View {
        Text(code)
            .font(.system(.body, design: .monospaced))
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
            .frame(width: LauncherCameraLabelsMetrics.codeColumnWidth, alignment: .leading)
            .help(code)
    }
}

private struct LauncherCameraFolderText: View {
    @ObservedObject var store: LauncherCameraCatalogStore
    let name: String

    var body: some View {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        Text(trimmed.isEmpty ? "" : (store.folderLabel(forName: trimmed) ?? ""))
            .font(.system(.callout, design: .monospaced))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .textSelection(.enabled)
            .frame(width: LauncherCameraLabelsMetrics.folderColumnWidth, alignment: .leading)
    }
}

private struct LauncherCameraNameField: View {
    @ObservedObject var store: LauncherCameraCatalogStore
    let code: String
    @Binding var name: String
    let accessibilityName: String
    var focus: FocusState<Bool>.Binding
    var onSubmit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            TextField("Name", text: $name, prompt: Text("Name"))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .focused(focus)
                .onSubmit(onSubmit)
                .accessibilityLabel(accessibilityName)
            LauncherCameraNameNotes(store: store, code: code, name: name)
        }
    }
}

private struct LauncherCameraNameNotes: View {
    @ObservedObject var store: LauncherCameraCatalogStore
    let code: String
    let name: String

    var body: some View {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            if let message = store.validationMessage(code: code, name: trimmed) {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(LauncherTone.error.color)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                let sharing = store.codesSharingFolder(code: code, name: trimmed)
                if !sharing.isEmpty {
                    Text("Same folder as \(sharing.joined(separator: ", ")).")
                        .font(.caption)
                        .foregroundStyle(LauncherTone.attention.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

private struct LauncherDetectedCameraRow: View {
    @ObservedObject var store: LauncherCameraCatalogStore
    let camera: LauncherDetectedCamera

    @State private var name = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        GridRow {
            LauncherCameraCodeText(code: camera.rawModelCode)
            LauncherCameraNameField(
                store: store,
                code: camera.rawModelCode,
                name: $name,
                accessibilityName: "Name for camera \(camera.rawModelCode)",
                focus: $isFocused,
                onSubmit: commit
            )
            LauncherCameraFolderText(store: store, name: name)
        }
        .onChange(of: isFocused) { focused in
            if !focused { commit() }
        }
    }

    private func commit() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        store.save(code: camera.rawModelCode, name: trimmed)
    }
}

private struct LauncherSavedCameraLabelRow: View {
    @ObservedObject var store: LauncherCameraCatalogStore
    let label: LauncherSavedCameraLabel

    @State private var draftName: String
    @FocusState private var isFocused: Bool

    init(store: LauncherCameraCatalogStore, label: LauncherSavedCameraLabel) {
        self.store = store
        self.label = label
        _draftName = State(initialValue: label.name)
    }

    var body: some View {
        GridRow {
            LauncherCameraCodeText(code: label.code)
            LauncherCameraNameField(
                store: store,
                code: label.code,
                name: $draftName,
                accessibilityName: "Name for camera \(label.code)",
                focus: $isFocused,
                onSubmit: commit
            )
            LauncherCameraFolderText(store: store, name: draftName)
            Button {
                store.delete(code: label.code)
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .frame(width: LauncherCameraLabelsMetrics.trailingColumnWidth)
            .help("Remove label")
            .accessibilityLabel("Remove label for \(label.code)")
        }
        .onChange(of: isFocused) { focused in
            if !focused { commit() }
        }
        .onChange(of: label.name) { newName in
            draftName = newName
        }
    }

    /// Clearing the field never deletes; the trash button is the only way to
    /// remove a label. A blank or unusable edit reverts to the saved name.
    private func commit() {
        let trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, store.validationMessage(code: label.code, name: trimmed) == nil else {
            draftName = label.name
            return
        }
        store.save(code: label.code, name: trimmed)
    }
}

private struct LauncherNewCameraLabelRow: View {
    @ObservedObject var store: LauncherCameraCatalogStore

    @State private var code = ""
    @State private var name = ""
    @FocusState private var focusedField: Field?

    private enum Field { case code, name }

    var body: some View {
        GridRow {
            TextField("Camera code", text: $code, prompt: Text("Camera code"))
                .labelsHidden()
                .font(.system(.body, design: .monospaced))
                .textFieldStyle(.roundedBorder)
                .frame(width: LauncherCameraLabelsMetrics.codeColumnWidth)
                .focused($focusedField, equals: .code)
                .onSubmit { focusedField = .name }
            VStack(alignment: .leading, spacing: 3) {
                TextField("Name", text: $name, prompt: Text("Name"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .name)
                    .onSubmit(add)
                LauncherCameraNameNotes(store: store, code: code, name: name)
                if let existingName = store.name(forCode: code) {
                    Text("Already labeled “\(existingName)”. Adding replaces it.")
                        .font(.caption)
                        .foregroundStyle(LauncherTone.attention.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            LauncherCameraFolderText(store: store, name: name)
            Button("Add", action: add)
                .disabled(validationMessage != nil)
        }
    }

    private var validationMessage: String? {
        store.validationMessage(code: code, name: name)
    }

    private func add() {
        guard validationMessage == nil else { return }
        guard store.save(code: code, name: name) else { return }
        code = ""
        name = ""
        focusedField = .code
    }
}

private struct LauncherCameraLabelExampleRow: View {
    var body: some View {
        GridRow {
            Text("AC006")
                .font(.system(.body, design: .monospaced))
                .frame(width: LauncherCameraLabelsMetrics.codeColumnWidth, alignment: .leading)
            HStack(spacing: 6) {
                Text("OsmoAction6")
                Text("Example")
                    .font(.caption)
            }
            Text("osmoaction6")
                .font(.system(.callout, design: .monospaced))
                .frame(width: LauncherCameraLabelsMetrics.folderColumnWidth, alignment: .leading)
        }
        .foregroundStyle(.tertiary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Example: camera code AC006 becomes OsmoAction6")
    }
}
