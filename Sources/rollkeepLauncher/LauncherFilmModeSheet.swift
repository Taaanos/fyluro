import RollKeepCore
import SwiftUI

struct LauncherFilmModeSheet: View {
    @ObservedObject var viewModel: LauncherViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var yearText: String
    @State private var month: Int?
    @State private var camera: String
    @State private var lens: String
    @State private var filmStock: String
    @State private var isoText: String
    @State private var shotAtISOText: String
    @State private var developmentNotes: String
    @State private var scannerSetup: String
    @State private var creator: String
    @State private var copyright: String

    private let isEditing: Bool

    /// `editing == nil`: a new roll. The sheet fills the camera, lens, stock and similar fields
    /// from the most recent roll. `editing != nil`: the sheet fills every field from the
    /// saved roll, so the user can fix one value and apply again.
    init(viewModel: LauncherViewModel, editing: FilmModeOverride? = nil) {
        self.viewModel = viewModel
        isEditing = editing != nil
        if let editing {
            _yearText = State(initialValue: String(editing.year))
            _month = State(initialValue: editing.month)
            _camera = State(initialValue: editing.camera)
            _lens = State(initialValue: editing.lens ?? "")
            _filmStock = State(initialValue: editing.filmStock ?? "")
            _isoText = State(initialValue: editing.iso.map(String.init) ?? "")
            _shotAtISOText = State(initialValue: editing.shotAtISO.map(String.init) ?? "")
            _developmentNotes = State(initialValue: editing.developmentNotes ?? "")
            _scannerSetup = State(initialValue: editing.scannerSetup ?? "")
            _creator = State(initialValue: editing.creator ?? "")
            _copyright = State(initialValue: editing.copyright ?? "")
            return
        }
        let mostRecent = viewModel.filmModeRemembering.loadHistory().first
        _yearText = State(initialValue: "")
        _month = State(initialValue: nil)
        _camera = State(initialValue: mostRecent?.camera ?? "")
        _lens = State(initialValue: mostRecent?.lens ?? "")
        _filmStock = State(initialValue: mostRecent?.filmStock ?? "")
        _isoText = State(initialValue: mostRecent?.iso.map(String.init) ?? "")
        // Shot-at-ISO and development notes are deliberately never prefilled:
        // most rolls aren't pushed/pulled, and notes are chemistry-batch
        // specific, so carrying forward a stale value risks mislabeling a
        // normal roll with an old roll's data.
        _shotAtISOText = State(initialValue: "")
        _developmentNotes = State(initialValue: "")
        _scannerSetup = State(initialValue: mostRecent?.scannerSetup ?? "")
        _creator = State(initialValue: mostRecent?.creator ?? "")
        _copyright = State(initialValue: mostRecent?.copyright ?? "")
    }

    private var trimmedCamera: String {
        camera.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var year: Int? {
        Int(yearText.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private var iso: Int? {
        Int(isoText.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private var shotAtISO: Int? {
        Int(shotAtISOText.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private var canApply: Bool {
        year != nil && month != nil && !trimmedCamera.isEmpty
    }

    private var cameraSuggestions: [String] {
        let allCameras = viewModel.filmModeRemembering.loadHistory().map(\.camera)
        let matches = trimmedCamera.isEmpty
            ? allCameras
            : allCameras.filter {
                $0.range(of: trimmedCamera, options: [.caseInsensitive]) != nil
                    && $0.caseInsensitiveCompare(trimmedCamera) != .orderedSame
            }
        return Array(matches.prefix(5))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            LauncherSettingsCard(
                title: "Film Mode",
                subtitle: "Declare this batch's month, camera, and film. \(AppBrand.name) uses these instead of the digitizing camera's EXIF, and writes them into each photo."
            ) {
                // Capped and scrollable: this form has grown past what fits
                // in a fixed-height sheet, and only Cancel/Apply (outside
                // this ScrollView, below) need to stay always visible.
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(alignment: .top, spacing: 10) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Month")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                Picker("Month", selection: $month) {
                                    Text("—").tag(Int?.none)
                                    ForEach(Array(Calendar.current.monthSymbols.enumerated()), id: \.offset) { index, symbol in
                                        Text(symbol).tag(Int?.some(index + 1))
                                    }
                                }
                                .labelsHidden()
                                .frame(width: 150)
                            }

                            VStack(alignment: .leading, spacing: 4) {
                                Text("Year")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                TextField("e.g. 1998", text: $yearText)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 90)
                            }
                        }

                        Divider()

                        VStack(alignment: .leading, spacing: 6) {
                            Text("Camera")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            TextField("e.g. Pentax K1000", text: $camera)
                                .textFieldStyle(.roundedBorder)

                            if !cameraSuggestions.isEmpty {
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 6) {
                                        ForEach(cameraSuggestions, id: \.self) { suggestion in
                                            Button(suggestion) { camera = suggestion }
                                                .buttonStyle(.bordered)
                                                .controlSize(.small)
                                        }
                                    }
                                }
                            }
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Lens (optional)")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            TextField("e.g. 50mm f/1.8", text: $lens)
                                .textFieldStyle(.roundedBorder)
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Film stock (optional)")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            TextField("e.g. Kodak Gold 200", text: $filmStock)
                                .textFieldStyle(.roundedBorder)
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text("ISO (optional)")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            TextField("e.g. 200", text: $isoText)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 90)
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Shot at ISO (optional)")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            TextField("e.g. 800", text: $shotAtISOText)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 90)
                            Text("If you rated this roll differently than its box speed — pushed or pulled — enter what you actually shot it at.")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Development notes (optional)")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            TextField("e.g. HC-110 dilution B, 9 min, pulled 1 stop", text: $developmentNotes)
                                .textFieldStyle(.roundedBorder)
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Scanner (optional)")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            TextField("e.g. Epson V600 + VueScan", text: $scannerSetup)
                                .textFieldStyle(.roundedBorder)
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Creator (optional)")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            TextField("e.g. Jane Doe", text: $creator)
                                .textFieldStyle(.roundedBorder)
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Copyright (optional)")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            TextField("e.g. © 1998 Jane Doe", text: $copyright)
                                .textFieldStyle(.roundedBorder)
                            Text("Leaving Creator or Copyright blank keeps whatever the source file already has for that field — it won't be cleared.")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .frame(maxHeight: LauncherWindowMetrics.filmModeSheetMaxHeight)
            }

            Spacer(minLength: 0)

            HStack {
                Button("Cancel", action: cancel)
                Spacer()
                Button("Apply", action: apply)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canApply)
            }
        }
        .padding(18)
        .frame(width: 380, alignment: .topLeading)
    }

    private func apply() {
        guard let year, let month else {
            return
        }

        let trimmedLens = lens.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedFilmStock = filmStock.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDevelopmentNotes = developmentNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedScannerSetup = scannerSetup.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedCreator = creator.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedCopyright = copyright.trimmingCharacters(in: .whitespacesAndNewlines)
        let override = FilmModeOverride(
            year: year,
            month: month,
            camera: trimmedCamera,
            lens: trimmedLens.isEmpty ? nil : trimmedLens,
            filmStock: trimmedFilmStock.isEmpty ? nil : trimmedFilmStock,
            iso: iso,
            shotAtISO: shotAtISO,
            developmentNotes: trimmedDevelopmentNotes.isEmpty ? nil : trimmedDevelopmentNotes,
            scannerSetup: trimmedScannerSetup.isEmpty ? nil : trimmedScannerSetup,
            creator: trimmedCreator.isEmpty ? nil : trimmedCreator,
            copyright: trimmedCopyright.isEmpty ? nil : trimmedCopyright
        )
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
