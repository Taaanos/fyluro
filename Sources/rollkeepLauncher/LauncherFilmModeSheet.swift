import RollKeepCore
import SwiftUI

/// A hint under a field or a section. It wraps to every line, starts at the leading edge,
/// and uses normal secondary text. A Form footer is right-aligned and bright without this.
private struct FilmModeFootnote: View {
    let text: String
    var tone: LauncherTone = .neutral

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(tone == .neutral ? AnyShapeStyle(.secondary) : AnyShapeStyle(tone.color))
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct LauncherFilmModeSheet: View {
    @ObservedObject var viewModel: LauncherViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var draft: FilmModeDraft
    @FocusState private var focusedField: Field?

    private enum Field {
        case year
        case camera
    }

    private let isEditing: Bool

    /// `editing == nil`: a new roll. The sheet fills the camera, lens, stock and similar fields
    /// from the most recent roll. `editing != nil`: the sheet fills every field from the
    /// saved roll, so the user can fix one value and apply again.
    init(viewModel: LauncherViewModel, editing: FilmModeOverride? = nil) {
        self.viewModel = viewModel
        isEditing = editing != nil
        if let editing {
            _draft = State(initialValue: FilmModeDraft(editing: editing))
        } else {
            _draft = State(initialValue: FilmModeDraft(remembering: viewModel.filmModeRemembering.loadHistory().first))
        }
    }

    private var cameraSuggestions: [String] {
        let allCameras = viewModel.filmModeRemembering.loadHistory().map(\.camera)
        let typed = draft.trimmedCamera
        let matches = typed.isEmpty
            ? allCameras
            : allCameras.filter {
                $0.range(of: typed, options: [.caseInsensitive]) != nil
                    && $0.caseInsensitiveCompare(typed) != .orderedSame
            }
        return Array(matches.prefix(5))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 12)

            Divider()

            // The Form scrolls by itself. Cancel and Apply stay below it, so they are always visible.
            Form {
                whenSection
                shotOnSection
                digitizedWithSection
                creditSection
            }
            .formStyle(.grouped)

            VStack(alignment: .leading, spacing: 8) {
                // Say why Apply is disabled. The text is outside the scroll area, so it is always visible.
                if let reason = draft.missingRequirementsMessage {
                    Text(reason)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                // Cancel and Apply sit together at the trailing edge. Return applies. Esc cancels.
                HStack {
                    Spacer()
                    Button("Cancel", action: cancel)
                        .keyboardShortcut(.cancelAction)
                    Button("Apply", action: apply)
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!draft.canApply)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(
            width: LauncherWindowMetrics.filmModeSheetWidth,
            height: LauncherWindowMetrics.filmModeSheetHeight,
            alignment: .topLeading
        )
        .onAppear {
            // Start in the first required text field that is still empty.
            // The focus change waits one turn so the sheet is on screen first.
            DispatchQueue.main.async {
                if draft.year == nil {
                    focusedField = .year
                } else if draft.trimmedCamera.isEmpty {
                    focusedField = .camera
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Film Mode")
                .font(.title3.weight(.semibold))
            Text("Scanned film carries the EXIF data of the device that digitized it. Film Mode records the camera and film that you shot on. It files the photos under the month that you shot them.")
                .foregroundStyle(.secondary)
            Text("Film Mode writes this data into JPEG, TIFF, HEIC and PNG files only. RAW files are not supported. They keep their original EXIF data, but they still go into the correct month folder.")
                .foregroundStyle(.secondary)
        }
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var whenSection: some View {
        Section {
            LabeledContent("Month and year shot") {
                HStack(spacing: 8) {
                    Picker("Month", selection: $draft.month) {
                        Text("—").tag(Int?.none)
                        ForEach(Array(Calendar.current.monthSymbols.enumerated()), id: \.offset) { index, symbol in
                            Text(symbol).tag(Int?.some(index + 1))
                        }
                    }
                    .labelsHidden()
                    .fixedSize()

                    TextField("Year", text: $draft.yearText, prompt: Text("1998"))
                        .labelsHidden()
                        .accessibilityLabel("Year")
                        .multilineTextAlignment(.trailing)
                        .frame(width: 64)
                        .focused($focusedField, equals: .year)
                }
            }
        } header: {
            Text("When")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                if let yearError = draft.yearError {
                    FilmModeFootnote(text: yearError, tone: .error)
                }
                FilmModeFootnote(text: "Month, year and camera are required. All other fields are optional.")
            }
        }
    }

    private var shotOnSection: some View {
        Section {
            TextField("Camera", text: $draft.camera, prompt: Text("Pentax K1000"))
                .focused($focusedField, equals: .camera)

            if !cameraSuggestions.isEmpty {
                Menu("Recent cameras") {
                    ForEach(cameraSuggestions, id: \.self) { suggestion in
                        Button(suggestion) { draft.camera = suggestion }
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }

            FilmModeFootnote(text: "Enter the camera that exposed the film. Do not enter the scanner or the camera that digitized the film.")

            TextField("Lens", text: $draft.lens, prompt: Text("50mm f/1.8"))
            TextField("Film stock", text: $draft.filmStock, prompt: Text("Kodak Gold 200"))

            LabeledContent("ISO") {
                HStack(spacing: 8) {
                    TextField("ISO", text: $draft.isoText, prompt: Text("200"))
                        .labelsHidden()
                        .accessibilityLabel("ISO")
                        .multilineTextAlignment(.trailing)
                        .frame(width: 64)
                    Text("Shot at")
                        .foregroundStyle(.secondary)
                    TextField("Shot at ISO", text: $draft.shotAtISOText, prompt: Text("800"))
                        .labelsHidden()
                        .accessibilityLabel("Shot at ISO")
                        .multilineTextAlignment(.trailing)
                        .frame(width: 64)
                }
            }

            if let isoError = draft.isoError {
                FilmModeFootnote(text: isoError, tone: .error)
            }

            TextField("Development notes", text: $draft.developmentNotes, prompt: Text("HC-110 dilution B, 9 min, pulled 1 stop"))
        } header: {
            Text("Shot on")
        } footer: {
            FilmModeFootnote(text: "If you rated the roll at a different speed than the box speed, enter that speed in \"Shot at\". This is for a pushed or pulled roll.")
        }
    }

    private var digitizedWithSection: some View {
        Section {
            TextField("Scanner or camera", text: $draft.scannerSetup, prompt: Text("Epson V600 + VueScan"))
        } header: {
            Text("Digitized with")
        } footer: {
            FilmModeFootnote(text: "The device that scanned or photographed the film.")
        }
    }

    private var creditSection: some View {
        Section {
            TextField("Creator", text: $draft.creator, prompt: Text("Jane Doe"))
            TextField("Copyright", text: $draft.copyright, prompt: Text("© 1998 Jane Doe"))
        } header: {
            Text("Credit")
        } footer: {
            FilmModeFootnote(text: "If you leave Creator or Copyright blank, the photo keeps the value that its source file has. The app does not clear it.")
        }
    }

    private func apply() {
        guard let override = draft.makeOverride() else {
            return
        }

        viewModel.applyFilmMode(override)
        dismiss()
    }

    /// A new roll that is cancelled leaves Film Mode off. An edit that is cancelled
    /// keeps the saved roll: only the switch turns Film Mode off.
    private func cancel() {
        if !isEditing {
            viewModel.disableFilmMode()
        }
        dismiss()
    }
}
