import Foundation
import RollKeepCore

/// The text and choices in the Film Mode sheet, before the user applies them.
/// The sheet edits this value. `makeOverride()` turns it into the `FilmModeOverride`
/// that the engine reads. The mapping rules live here so tests can check them.
struct FilmModeDraft: Equatable {
    var yearText = ""
    var month: Int?
    var camera = ""
    var lens = ""
    var filmStock = ""
    var isoText = ""
    var shotAtISOText = ""
    var developmentNotes = ""
    var scannerSetup = ""
    var creator = ""
    var copyright = ""

    /// A new roll with every field empty.
    init() {}

    /// Fills every field from a saved roll, so the user can fix one value and apply again.
    init(editing override: FilmModeOverride) {
        yearText = String(override.year)
        month = override.month
        camera = override.camera
        lens = override.lens ?? ""
        filmStock = override.filmStock ?? ""
        isoText = override.iso.map(String.init) ?? ""
        shotAtISOText = override.shotAtISO.map(String.init) ?? ""
        developmentNotes = override.developmentNotes ?? ""
        scannerSetup = override.scannerSetup ?? ""
        creator = override.creator ?? ""
        copyright = override.copyright ?? ""
    }

    /// A new roll. Fills the camera, lens, stock and similar fields from the most recent roll.
    init(remembering mostRecent: LauncherFilmModeHistoryEntry?) {
        camera = mostRecent?.camera ?? ""
        lens = mostRecent?.lens ?? ""
        filmStock = mostRecent?.filmStock ?? ""
        isoText = mostRecent?.iso.map(String.init) ?? ""
        scannerSetup = mostRecent?.scannerSetup ?? ""
        creator = mostRecent?.creator ?? ""
        copyright = mostRecent?.copyright ?? ""
        // Year, month, shot-at-ISO and development notes are deliberately never prefilled.
        // Year and month change for every roll. Most rolls are not pushed or pulled, and
        // notes are specific to one chemistry batch, so an old value could label a normal
        // roll with the data of an old roll.
    }

    var trimmedCamera: String {
        Self.trimmed(camera)
    }

    var year: Int? {
        Int(Self.trimmed(yearText))
    }

    var iso: Int? {
        Int(Self.trimmed(isoText))
    }

    var shotAtISO: Int? {
        Int(Self.trimmed(shotAtISOText))
    }

    var canApply: Bool {
        year != nil && month != nil && !trimmedCamera.isEmpty
    }

    /// Returns nil until the year, the month and the camera are set.
    /// A blank optional field becomes nil. A blank Creator or Copyright keeps the value
    /// that the source file has. This is on purpose.
    func makeOverride() -> FilmModeOverride? {
        guard canApply, let year, let month else {
            return nil
        }

        return FilmModeOverride(
            year: year,
            month: month,
            camera: trimmedCamera,
            lens: Self.nilIfEmpty(lens),
            filmStock: Self.nilIfEmpty(filmStock),
            iso: iso,
            shotAtISO: shotAtISO,
            developmentNotes: Self.nilIfEmpty(developmentNotes),
            scannerSetup: Self.nilIfEmpty(scannerSetup),
            creator: Self.nilIfEmpty(creator),
            copyright: Self.nilIfEmpty(copyright)
        )
    }

    private static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func nilIfEmpty(_ text: String) -> String? {
        let value = trimmed(text)
        return value.isEmpty ? nil : value
    }
}
