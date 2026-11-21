import Foundation
import FyluroCore

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

    /// The year of the first photograph. No film photo is older.
    static let earliestYear = 1826

    /// The latest year that the sheet accepts. Tests set it to get the same result on every date.
    var currentYear = Calendar.current.component(.year, from: Date())

    init() {}

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
        let text = Self.trimmed(yearText)
        guard text.count == 4,
              text.allSatisfy({ $0.isASCII && $0.isNumber }),
              let value = Int(text),
              (Self.earliestYear...currentYear).contains(value)
        else {
            return nil
        }
        return value
    }

    var yearError: String? {
        guard !Self.trimmed(yearText).isEmpty, year == nil else {
            return nil
        }
        return "Enter a four-digit year from \(Self.earliestYear) to \(currentYear)."
    }

    var iso: Int? {
        Self.positiveWholeNumber(isoText)
    }

    var shotAtISO: Int? {
        Self.positiveWholeNumber(shotAtISOText)
    }

    var isoError: String? {
        let isoIsInvalid = !Self.trimmed(isoText).isEmpty && iso == nil
        let shotAtIsInvalid = !Self.trimmed(shotAtISOText).isEmpty && shotAtISO == nil
        guard isoIsInvalid || shotAtIsInvalid else {
            return nil
        }
        return "Enter ISO as a whole number above 0, or leave it blank."
    }

    var canApply: Bool {
        year != nil && month != nil && !trimmedCamera.isEmpty && isoError == nil
    }

    var missingRequirementsMessage: String? {
        var steps: [String] = []
        if month == nil {
            steps.append("choose a month")
        }
        if year == nil {
            steps.append(yearError == nil ? "enter a year" : "enter a valid year")
        }
        if trimmedCamera.isEmpty {
            steps.append("name the camera")
        }
        if isoError != nil {
            steps.append("fix the ISO")
        }
        guard !steps.isEmpty else {
            return nil
        }

        let joined: String
        switch steps.count {
        case 1:
            joined = steps[0]
        case 2:
            joined = "\(steps[0]) and \(steps[1])"
        default:
            joined = steps.dropLast().joined(separator: ", ") + ", and " + steps[steps.count - 1]
        }
        return joined.prefix(1).uppercased() + joined.dropFirst() + "."
    }

    /// A blank Creator or Copyright stays nil so the engine keeps the source file's value.
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

    private static func positiveWholeNumber(_ text: String) -> Int? {
        let value = trimmed(text)
        guard value.allSatisfy({ $0.isASCII && $0.isNumber }),
              let number = Int(value),
              number > 0
        else {
            return nil
        }
        return number
    }

    private static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func nilIfEmpty(_ text: String) -> String? {
        let value = trimmed(text)
        return value.isEmpty ? nil : value
    }
}
