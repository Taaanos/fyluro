import Foundation
import RollKeepCore
import XCTest
@testable import rollkeepLauncher

final class FilmModeDraftTests: XCTestCase {
    private func validDraft() -> FilmModeDraft {
        var draft = FilmModeDraft()
        draft.currentYear = 2026
        draft.yearText = "1998"
        draft.month = 7
        draft.camera = "Pentax K1000"
        return draft
    }

    func testEmptyDraftCannotApply() {
        let draft = FilmModeDraft()
        XCTAssertFalse(draft.canApply)
        XCTAssertNil(draft.makeOverride())
    }

    func testYearMonthAndCameraAreRequired() {
        var draft = validDraft()
        XCTAssertTrue(draft.canApply)

        draft.camera = "   "
        XCTAssertFalse(draft.canApply)

        draft = validDraft()
        draft.month = nil
        XCTAssertFalse(draft.canApply)

        draft = validDraft()
        draft.yearText = "abc"
        XCTAssertFalse(draft.canApply)
    }

    func testMakeOverrideTrimsValuesAndTurnsEmptyOptionalsIntoNil() {
        var draft = validDraft()
        draft.yearText = " 1998 "
        draft.camera = "  Pentax K1000 \n"
        draft.lens = "  "
        draft.filmStock = " Kodak Gold 200 "

        let override = draft.makeOverride()

        XCTAssertEqual(override?.year, 1998)
        XCTAssertEqual(override?.month, 7)
        XCTAssertEqual(override?.camera, "Pentax K1000")
        XCTAssertNil(override?.lens)
        XCTAssertEqual(override?.filmStock, "Kodak Gold 200")
        XCTAssertNil(override?.iso)
        XCTAssertNil(override?.shotAtISO)
        XCTAssertNil(override?.developmentNotes)
        XCTAssertNil(override?.scannerSetup)
        // A blank Creator or Copyright must stay nil. The engine then keeps the source value.
        XCTAssertNil(override?.creator)
        XCTAssertNil(override?.copyright)
    }

    func testMakeOverrideParsesISOFields() {
        var draft = validDraft()
        draft.isoText = " 200 "
        draft.shotAtISOText = "800"

        let override = draft.makeOverride()

        XCTAssertEqual(override?.iso, 200)
        XCTAssertEqual(override?.shotAtISO, 800)
    }

    func testEditingFillsEveryFieldAndRoundTrips() {
        let saved = FilmModeOverride(
            year: 1998,
            month: 7,
            camera: "Leica M6",
            lens: "50mm f/2",
            filmStock: "Portra 400",
            iso: 400,
            shotAtISO: 1600,
            developmentNotes: "Pulled 1 stop",
            scannerSetup: "Epson V600",
            creator: "Jane Doe",
            copyright: "© 1998 Jane Doe"
        )

        let draft = FilmModeDraft(editing: saved)

        XCTAssertEqual(draft.yearText, "1998")
        XCTAssertEqual(draft.month, 7)
        XCTAssertEqual(draft.shotAtISOText, "1600")
        XCTAssertEqual(draft.developmentNotes, "Pulled 1 stop")
        XCTAssertEqual(draft.makeOverride(), saved)
    }

    func testRememberingFillsEquipmentButNeverDateShotAtISOOrNotes() {
        let entry = LauncherFilmModeHistoryEntry(
            camera: "Leica M6",
            filmStock: "Portra 400",
            iso: 400,
            creator: "Jane Doe",
            copyright: "© 2026 Jane Doe",
            lens: "50mm f/2",
            scannerSetup: "Epson V600"
        )

        let draft = FilmModeDraft(remembering: entry)

        XCTAssertEqual(draft.camera, "Leica M6")
        XCTAssertEqual(draft.lens, "50mm f/2")
        XCTAssertEqual(draft.filmStock, "Portra 400")
        XCTAssertEqual(draft.isoText, "400")
        XCTAssertEqual(draft.scannerSetup, "Epson V600")
        XCTAssertEqual(draft.creator, "Jane Doe")
        XCTAssertEqual(draft.copyright, "© 2026 Jane Doe")
        XCTAssertEqual(draft.yearText, "")
        XCTAssertNil(draft.month)
        XCTAssertEqual(draft.shotAtISOText, "")
        XCTAssertEqual(draft.developmentNotes, "")
    }

    func testRememberingWithoutHistoryGivesAnEmptyDraft() {
        XCTAssertEqual(FilmModeDraft(remembering: nil), FilmModeDraft())
    }

    func testYearMustHaveFourDigitsAndBeInRange() {
        var draft = validDraft()
        let valid = ["1826", "1998", "2026", " 2000 "]
        for text in valid {
            draft.yearText = text
            XCTAssertEqual(draft.year, Int(text.trimmingCharacters(in: .whitespaces)), text)
            XCTAssertNil(draft.yearError, text)
        }

        let invalid = ["1825", "2027", "98", "019", "19980", "+199", "-199", "19.8", "1 98", "١٩٩٨"]
        for text in invalid {
            draft.yearText = text
            XCTAssertNil(draft.year, text)
            XCTAssertNotNil(draft.yearError, text)
            XCTAssertFalse(draft.canApply, text)
            XCTAssertNil(draft.makeOverride(), text)
        }
    }

    func testEmptyYearHasNoErrorButBlocksApply() {
        var draft = validDraft()
        draft.yearText = ""
        XCTAssertNil(draft.yearError)
        XCTAssertFalse(draft.canApply)
    }

    func testISOMustBeAWholeNumberAboveZeroOrBlank() {
        var draft = validDraft()
        XCTAssertNil(draft.isoError)

        for text in ["200", " 3200 "] {
            draft.isoText = text
            XCTAssertNotNil(draft.iso, text)
            XCTAssertNil(draft.isoError, text)
            XCTAssertTrue(draft.canApply, text)
        }

        for text in ["0", "-100", "abc", "2e2", "1.5", "99999999999999999999"] {
            draft = validDraft()
            draft.isoText = text
            XCTAssertNil(draft.iso, text)
            XCTAssertNotNil(draft.isoError, text)
            XCTAssertFalse(draft.canApply, text)

            draft = validDraft()
            draft.shotAtISOText = text
            XCTAssertNotNil(draft.isoError, text)
            XCTAssertNil(draft.makeOverride(), text)
        }
    }

    func testMissingRequirementsMessageNamesWhatIsMissing() {
        var draft = FilmModeDraft()
        draft.currentYear = 2026
        XCTAssertEqual(draft.missingRequirementsMessage, "Choose a month, enter a year, and name the camera.")

        draft.month = 3
        XCTAssertEqual(draft.missingRequirementsMessage, "Enter a year and name the camera.")

        draft.yearText = "98"
        XCTAssertEqual(draft.missingRequirementsMessage, "Enter a valid year and name the camera.")

        draft.yearText = "1998"
        XCTAssertEqual(draft.missingRequirementsMessage, "Name the camera.")

        draft.camera = "Pentax K1000"
        XCTAssertNil(draft.missingRequirementsMessage)

        draft.isoText = "abc"
        XCTAssertEqual(draft.missingRequirementsMessage, "Fix the ISO.")
    }
}
