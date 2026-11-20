# UI-S2: Film Mode sheet

**Status:** Done and merged (owner review 2026-10-05) · **Depends on:** S0 merged; S1 ticket 1.3 (adds the `editing:` init and the rule "Cancel must not turn off Film Mode when editing") · **Branch:** `ui/s2-film-mode-sheet` · **Size:** small to medium

## Confirmed decisions (owner, 2026-10-05)

1. **Grouping:** by role, as recommended. When (month, year) · Shot on (camera, lens, film stock, ISO, shot-at ISO, development notes) · Digitized with (scanner or copy-camera setup) · Credit (creator, copyright).
2. **Text:** write it in ASD-STE100. The text must also say that Film Mode writes EXIF into non-RAW files only (JPEG, TIFF, HEIC, PNG). RAW files keep their EXIF but still go into the correct month folder.
   - Subtitle: "Scanned film carries the EXIF data of the device that digitized it. Film Mode records the camera and film that you shot on. It files the photos under the month that you shot them."
   - Note under the subtitle: "Film Mode writes this data into JPEG, TIFF, HEIC and PNG files only. RAW files keep their original EXIF data. They still go into the correct month folder."
   - Help text under "Shot on": "Enter the camera that exposed the film. Do not enter the scanner or the camera that digitized the film."
3. **Year rule:** four digits, 1826 to the current year. UI only.
4. **Hints:** section footers in `.secondary` text.
5. **Camera suggestions:** a compact menu under the Camera field.
6. **Size:** Fixed sheet width of about 480 pt. The Form scrolls inside the sheet. Cancel and Apply stay pinned below the scroll area. Month and Year share one row, and ISO and Shot at ISO share one row, to keep the form short.
   Reason: a sheet is a short task, so it has a fixed size. A split or a step flow is too much for 3 required fields. A scrolling grouped form is the macOS norm.

## Result (2026-10-05)

Tickets 2.1, 2.2 and 2.3 are done, one commit each. Gates: `swift build` (no new warnings), `swift test` and `scripts/run-e2e-tests.sh` all pass. New tests: `FilmModeDraftTests` (11 tests).

Changes you can see:
- The sheet is a grouped Form: When, Shot on, Digitized with, Credit. It is 480 x 640 pt. The Form scrolls and the buttons stay below it.
- The text says that EXIF is written into JPEG, TIFF, HEIC and PNG only.
- ISO fields that hold text that is not a whole number above 0 now block Apply. Before, the app dropped that text silently. This is a small behavior change in the UI only. The engine is the same.
- Camera suggestions are a "Recent cameras" menu under the Camera field.

Screenshot review (2026-10-05, owner screenshots in `after/`, which git ignores):
- The first dark screenshots showed three problems: the Camera hint was cut off, the Form footers were right-aligned and bright, and scrolled rows had no edge under the header. Fixed in `c812ffe`.
- The failure screen cut its message at one line (an S3 bug). Fixed in `f964039`.
- After the fixes, the light screenshots show: hints wrap and are left-aligned in secondary color; an invalid year (1799) shows the red error and the reason line "Choose a month and enter a valid year."; Apply is disabled; the failure message wraps in full.

Checks still open:
- [x] The sheet in dark appearance after the fixes. The owner said it looks OK (2026-10-05).
- [x] Return (apply), Esc (cancel). Owner: works (2026-10-05).
- [x] Add, apply, then Edit… and Cancel. The saved roll stays. Owner: works (2026-10-05).
- [x] A real Film Mode import of `RK_IPHONE` into `RK_DEST` (owner, 2026-10-05). Result:
  - The Complete screen shows the Film Mode line and the RAW notice for 2 DNG files.
  - The 4 HEIC and PNG photos are in `1992/199203/goprofilm/Photos/Non-RAW/`. The 2 DNG files are in `.../RAW/`.
  - `exiftool` shows that the HEIC and PNG files have the new model, date (1992:03:01), lens, ISO and creator. The DNG files still show Apple and iPhone 15 Pro. This matches the RAW limit in ROL-6 s5.
  - The filesystem date of the HEIC equals the source date (I-8).
  - The 4 videos and the audio file use their own dates and the iPhone camera labels. Film Mode only changes photos.
- [x] Sheet height 640 pt: the owner raised no problem after seeing it on screen (2026-10-05). Kept.

Observation for S6 (not S2): on the Complete screen, the three plain actions ("View Receipt", "Open Source", "Import Another Card") look like disabled text in light appearance. Check their contrast.

## Purpose to design around (user, 2026-10-04)

Film Mode has one purpose: give metadata for **film** photos. The main point is *which camera and film made the shots*. The file's own EXIF describes the device that digitized it. Every part of this sheet must make this clear. The film side ("Shot on") is the headline. The digitization side ("Digitized with") is a separate, optional detail (findings H1).

## Goal

Change the 11-field single-column scroll into a native, grouped macOS form. The form:
- shows the required fields clearly,
- tells the user why *Apply* is disabled,
- checks the year,
- follows the macOS button conventions.

**Film Mode does the same thing as before:** the same `FilmModeOverride`, the same fill rules, the same engine contract.

## Why (principles)

- **Native first (#2).** `Form` with `.formStyle(.grouped)` and `LabeledContent` is the macOS way to lay out labeled fields (labels at the left, controls aligned). It replaces about 100 lines of hand-made "caption above field" stacks and the card inside the sheet.
- **Hierarchy (#1).** Today 3 required and 8 optional fields have equal weight. Group them by meaning. State "required" once. Do not write "(optional)" 8 times.
- **Feedback.** A disabled main button with no reason is a dead end (B2). `.tertiary` 11-pt hints are hard to read (B1).
- **Consistency (#6).** The macOS sheet convention: Cancel and the default action are together at the trailing edge. Return is the default. Esc cancels.

## Read first

`AGENTS.md`, `docs/ROL-6-spec-and-invariants.md` (§3 Film Mode exception, §5 Film Mode override and RAW limit), [README](README.md), [findings.md](findings.md) B1–B4, H1.
Files: `LauncherFilmModeSheet.swift`, `LauncherFilmModeMemory.swift` (and `LauncherFilmModeMemoryTests.swift`), `Sources/FyluroCore/FilmModeOverride.swift` (**the engine has no range check**), `LauncherSettingsViews.swift` (`LauncherSettingsCard`; remove it from the sheet only).

## Decisions to confirm before you write code

1. **Group and label by *role*, not by field type.** *Recommendation:*
   - **When:** Month and Year *(required; label "Month and year shot")*.
   - **Shot on:** **Camera** *(required; label "Shot on" or "Camera used for the film shots")*, Lens, Film stock, ISO, Shot at ISO, Development notes.
   - **Digitized with:** scanner or copy-camera setup *(optional; replaces "Scanner (optional)")*.
   - **Credit:** Creator, Copyright.

   Reason: today "Camera" is above "Scanner" and nothing says which device is which (H1). Other option: keep the technical grouping (The roll / Equipment / Film / Credit) and only rename the labels.
2. **Text with the purpose first.** *Recommendation* for the sheet subtitle: *"Scanned film carries the EXIF of whatever digitized it. Film Mode records the camera and film you actually shot on, and files the photos under the month you shot them."* Helper text under "Shot on": *"The camera that exposed the film — not the scanner or camera used to digitize it."* Confirm the wording.
3. **Year rule (UI only; the engine accepts any `Int`).** *Recommendation:* exactly four digits, from 1826 (the first photograph) to the current year. Show an inline message for an invalid year. Confirm the lower limit.
4. **Where do the two hints go** ("pushed or pulled…", "a blank Creator/Copyright keeps the source value")? *Recommendation:* as section footers in normal `.secondary` text (not `.tertiary`).
5. **Camera suggestions** (recent cameras as chips, from history). *Recommendation:* keep the behavior. Show them in a compact menu or chips under the Camera field. Confirm chips or menu.
6. **Sheet width.** *Recommendation:* about 480 pt (now 380). The Form scrolls by itself if it must.

## Tickets

### UI-2.1 — `Form` regroup and `FilmModeDraft`
- Move the 11 `@State` fields into a small value type `FilmModeDraft` (strings in, `FilmModeOverride?` out). Then tests can check the mapping and validation. `makeOverride()` keeps today's rules: trimmed values, empty optional becomes `nil`, `iso` and `shotAtISO` parsed from text, `camera` trimmed and required.
- Fill: `init(editing:)` from S1.3 (the full override), or from `filmModeRemembering.loadHistory().first` (camera, lens, film stock, ISO, scanner, creator, copyright). **Never** fill year, month, shot-at-ISO, or development notes. Keep the existing code comment that explains why.
- Remove the `LauncherSettingsCard` around the form. The Form is the sheet content. Remove the 420 pt scroll cap (`filmModeSheetMaxHeight`) if the Form fits. If not, use the Form's own scrolling.
- Use the confirmed grouping, labels, and text (decisions 1, 2): "Shot on" for the camera field and "Digitized with" for the scanner field. **The field meanings and the `FilmModeOverride` mapping do not change.** Only labels, order, and helper text change. `camera` stays the required free-text camera. `scannerSetup` stays the optional digitization note.
- Replace the app-name literal in the subtitle with `AppBrand.name` (if S0 left it).
- Tests: add `FilmModeDraftTests`. Cover trimming, nil for empty, year and ISO parsing, `canApply`, fill from history and from editing, and that history never fills shot-at-ISO or notes.
- Acceptance: ☐ every field is present and the same inputs make the same override ☐ no "(optional)" suffixes; "required" is marked once ☐ no card inside the sheet.

### UI-2.2 — Validation and the reason for disabled
- Year: numeric input with the confirmed rule. Show an inline error under the field when the year is invalid and not empty. ISO and Shot at ISO: digits only, positive.
- Show why Apply is disabled, under the buttons or in the footer of "When": "Choose a month, enter a year, and name the camera." Show it only while something is missing.
- Acceptance: ☐ an invalid year never reaches `applyFilmMode` ☐ the reason names the missing fields ☐ a valid year clears the message.

### UI-2.3 — Buttons and keyboard
- Put Cancel and Apply together at the trailing edge. Apply has `.keyboardShortcut(.defaultAction)`. Cancel has `.keyboardShortcut(.cancelAction)`. Initial focus goes to the first empty required field.
- Cancel while **adding** (no saved override): leave Film Mode off. Cancel while **editing**: keep the saved override unchanged (S1.3 rule).
- Acceptance: ☐ Return applies when the form is valid ☐ Esc cancels ☐ Cancel while editing never clears the saved roll.

## Out of scope

Changes to what the app writes to EXIF. RAW support. New fields. The Film Mode row on the main window (S1.3).

## Verification

`swift build` · `swift test` (new `FilmModeDraftTests`; `LauncherFilmModeMemoryTests` still pass) · `scripts/run-dev-app.sh`.
- Do: add, apply, edit, cancel, switch off.
- Try an invalid year, a blank camera, and a very long development note.
- Check light and dark. Save `after/film-sheet-*.png`.
- Optional: do one real Film Mode import on a copy of a JPEG fixture. Check that the folder and EXIF match the input.

## Spec check

ROL-6 §3 (Film Mode is the one approved metadata rewrite; the UI must not imply anything else), §5 (field list and RAW limit). §4 placement rules do not change.
