import RollKeepCore
import SwiftUI

struct LauncherFilmModeSheet: View {
    @ObservedObject var viewModel: LauncherViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var yearText: String
    @State private var month: Int?
    @State private var camera: String
    @State private var filmStock: String
    @State private var isoText: String
    @State private var creator: String
    @State private var copyright: String

    init(viewModel: LauncherViewModel) {
        self.viewModel = viewModel
        let mostRecent = viewModel.filmModeRemembering.loadHistory().first
        _yearText = State(initialValue: "")
        _month = State(initialValue: nil)
        _camera = State(initialValue: mostRecent?.camera ?? "")
        _filmStock = State(initialValue: mostRecent?.filmStock ?? "")
        _isoText = State(initialValue: mostRecent?.iso.map(String.init) ?? "")
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
                subtitle: "Declare this batch's month, camera, and film. RollKeep uses these instead of the digitizing camera's EXIF, and writes them into each photo."
            ) {
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

        let trimmedFilmStock = filmStock.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedCreator = creator.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedCopyright = copyright.trimmingCharacters(in: .whitespacesAndNewlines)
        let override = FilmModeOverride(
            year: year,
            month: month,
            camera: trimmedCamera,
            filmStock: trimmedFilmStock.isEmpty ? nil : trimmedFilmStock,
            iso: iso,
            creator: trimmedCreator.isEmpty ? nil : trimmedCreator,
            copyright: trimmedCopyright.isEmpty ? nil : trimmedCopyright
        )
        viewModel.applyFilmMode(override)
        dismiss()
    }

    private func cancel() {
        viewModel.disableFilmMode()
        dismiss()
    }
}
