import RollKeepCore
import SwiftUI

struct LauncherCameraLabelsSettingsView: View {
    @ObservedObject var store: LauncherCameraCatalogStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Name your cameras so library folders read \"osmoaction6\" instead of \"ac006\".")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let warning = store.loadWarning {
                    LauncherCameraLabelsBanner(icon: "exclamationmark.triangle.fill", tint: .orange, text: warning)
                }
                if let notice = store.recoveryNotice {
                    LauncherCameraLabelsBanner(icon: "info.circle.fill", tint: .blue, text: notice)
                }
                if let error = store.saveError {
                    LauncherCameraLabelsBanner(icon: "xmark.octagon.fill", tint: .red, text: error)
                }

                LauncherSettingsCard(
                    title: "On the Current Card",
                    subtitle: "Cameras found on the scanned card that don't have a label yet."
                ) {
                    currentCardContent
                }

                LauncherSettingsCard(
                    title: "Your Labels",
                    subtitle: "Saved as you type. Add a camera even if it isn't on the card.",
                    accent: .green
                ) {
                    yourLabelsContent
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(
            width: LauncherSettingsWindowMetrics.width,
            height: LauncherSettingsWindowMetrics.height,
            alignment: .topLeading
        )
        .onAppear { store.reload() }
    }

    @ViewBuilder
    private var currentCardContent: some View {
        let cameras = store.unmappedDetectedCameras
        if cameras.isEmpty {
            Text(store.detectedCameras.isEmpty
                 ? "Insert a card to see its cameras here."
                 : "Every camera on this card already has a label.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(cameras) { camera in
                    LauncherDetectedCameraRow(store: store, camera: camera)
                }
            }
        }
    }

    @ViewBuilder
    private var yourLabelsContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            let labels = store.savedLabels
            if labels.isEmpty {
                LauncherCameraLabelExampleRow()
            } else {
                ForEach(labels) { label in
                    LauncherSavedCameraLabelRow(store: store, label: label)
                }
                Divider()
            }

            LauncherNewCameraLabelRow(store: store)
        }
    }
}

private enum LauncherCameraLabelsMetrics {
    static let codeColumnWidth: CGFloat = 120
    static let trailingColumnWidth: CGFloat = 26
}

private struct LauncherCameraLabelsBanner: View {
    let icon: String
    let tint: Color
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint)
                .padding(.top, 1)
            Text(text)
                .font(.caption)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(tint.opacity(0.1)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(tint.opacity(0.35), lineWidth: 0.8))
    }
}

private struct LauncherCameraCodeText: View {
    let code: String

    var body: some View {
        Text(code)
            .font(.system(.body, design: .monospaced))
            .lineLimit(1)
            .truncationMode(.middle)
            .textSelection(.enabled)
            .frame(width: LauncherCameraLabelsMetrics.codeColumnWidth, alignment: .leading)
            .help(code)
    }
}

/// Live result of what the user typed: labels are ASCII, lowercase and
/// kebab-case, so the folder name is not the name typed.
private struct LauncherCameraFolderPreview: View {
    @ObservedObject var store: LauncherCameraCatalogStore
    let code: String
    let name: String

    var body: some View {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            EmptyView()
        } else if let folder = store.folderLabel(forName: trimmed) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Folder: \(folder)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                let sharing = store.codesSharingFolder(code: code, name: trimmed)
                if !sharing.isEmpty {
                    Text("Same folder as \(sharing.joined(separator: ", ")).")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        } else {
            Text("Use at least one letter or number (A-Z, 0-9). Other characters are dropped from folder names.")
                .font(.caption)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct LauncherDetectedCameraRow: View {
    @ObservedObject var store: LauncherCameraCatalogStore
    let camera: LauncherDetectedCamera

    @State private var name = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                LauncherCameraCodeText(code: camera.rawModelCode)
                Image(systemName: "arrow.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("Name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .focused($isFocused)
                    .onSubmit(commit)
                    .accessibilityLabel("Name for camera \(camera.rawModelCode)")
            }
            LauncherCameraFolderPreview(store: store, code: camera.rawModelCode, name: name)
                .padding(.leading, LauncherCameraLabelsMetrics.codeColumnWidth + 8 + 12 + 8)
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
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                LauncherCameraCodeText(code: label.code)
                Image(systemName: "arrow.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("Name", text: $draftName)
                    .textFieldStyle(.roundedBorder)
                    .focused($isFocused)
                    .onSubmit(commit)
                    .accessibilityLabel("Name for camera \(label.code)")
                Button {
                    store.delete(code: label.code)
                } label: {
                    Image(systemName: "trash")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .frame(width: LauncherCameraLabelsMetrics.trailingColumnWidth)
                .help("Remove this label")
                .accessibilityLabel("Remove label for \(label.code)")
            }
            LauncherCameraFolderPreview(store: store, code: label.code, name: draftName)
                .padding(.leading, LauncherCameraLabelsMetrics.codeColumnWidth + 8 + 12 + 8)
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
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                TextField("Camera code", text: $code)
                    .font(.system(.body, design: .monospaced))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: LauncherCameraLabelsMetrics.codeColumnWidth)
                    .focused($focusedField, equals: .code)
                    .onSubmit { focusedField = .name }
                Image(systemName: "arrow.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("Name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .name)
                    .onSubmit(add)
                Button("Add", action: add)
                    .disabled(validationMessage != nil)
            }

            if !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                LauncherCameraFolderPreview(store: store, code: code, name: name)
                    .padding(.leading, LauncherCameraLabelsMetrics.codeColumnWidth + 8 + 12 + 8)
            }

            if let existingName = store.name(forCode: code) {
                Text("Already labeled \"\(existingName)\". Adding replaces it.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
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
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text("AC006")
                    .font(.system(.body, design: .monospaced))
                    .frame(width: LauncherCameraLabelsMetrics.codeColumnWidth, alignment: .leading)
                Image(systemName: "arrow.right")
                    .font(.caption)
                Text("OsmoAction6")
                Spacer(minLength: 0)
                Text("Example")
                    .font(.caption)
            }
            Text("Folder: osmoaction6")
                .font(.caption.monospaced())
                .padding(.leading, LauncherCameraLabelsMetrics.codeColumnWidth + 8 + 12 + 8)
        }
        .foregroundStyle(.tertiary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Example: camera code AC006 becomes OsmoAction6")
    }
}
