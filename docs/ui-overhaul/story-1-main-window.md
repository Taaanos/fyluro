# UI-S1: Main window (setup state)

**Status:** Done. The owner tried the build and approved it (2026-10-04). Branch `ui/s1-main-window` is not merged yet. · **Depends on:** S0 merged · **Branch:** `ui/s1-main-window` · **Size:** large (one commit for each ticket)

## Confirmed decisions (user, 2026-10-04)

1. Add **Edit…** to the Film Mode row. The sheet opens with the saved values. Cancel while editing keeps the saved roll. This reverses the old "strictly binary" design.
2. One merged route panel with two rows and a connector.
3. The camera "Name…" link moves to S5. S1 only restyles the row.
4. Window sizing: try native `.windowResizability(.contentSize)` first. If a state clips or jumps, keep a fixed window size and scroll inside.
6. Owner change after trying the build (2026-10-04): the Scan Preview shows nothing until a source is chosen. The Choose and Change buttons stay. The whole setup window is an invisible drop target for the source only. The window shows no drop zone. The destination takes no drop. This replaces the visible drop zone in 1.2 and the per-row drops in 1.1.
5. The Film-Mode-on row uses the accent tint and the film icon. It starts with the film camera.

## Goal

Make the setup screen easy to read at a glance: where from, where to, what is on the card, go.
The Source→Destination route is the spine of the screen. The Scan Preview is a compact evidence panel. Film Mode is visible and editable when on. The window stops fighting SwiftUI.

## Why (principles)

- **Hierarchy (#1).** Today three equal heavy cards, a toggle, and a button have the same weight. One route panel and one summary read in one pass.
- **Proximity (#3).** Free space belongs next to the destination (A4), not inside the Scan Preview of the source.
- **Show state where the user can see and edit it (#4).** Film Mode has one valid purpose: record the camera and film that made the shots, not the scanner or camera that digitized them (README decision; findings H). The user typed this fact and must be able to trust it. It must not be small gray text with no way back in (A8, H2). The row is prominent so the user is sure the right camera is recorded. It is not a warning.
- **Say it once (#7).** The empty state repeats itself 3 times (A6).
- **Native first (#2).** Resizing the window by hand on each layout pass (A9) works against the system.

## Read first

`AGENTS.md`, `docs/ROL-6-spec-and-invariants.md` (§3 Film Mode exception, §4, §6), [README](README.md), [findings.md](findings.md) A1–A10.
Files: `LauncherContentView.swift`, `LauncherSetupViews.swift`, `LauncherRouteViews.swift`, `LauncherFilmModeToggleRow.swift`, `LauncherFilmModeSheet.swift`, `RollkeepLauncherApp.swift`, `LauncherViewModel.swift`, `LauncherViewModelPresentation.swift`, `LauncherFolderDropResolver.swift`.
Tests to know:
- `LauncherCoreViewModelDefaultsActionsTests.swift:49` pins `statusMessage == "Choose a readable source to begin."`.
- `LauncherCoreParserStatusTests.swift:396` pins `LauncherWindowMetrics`.
- `LauncherFolderDropResolverTests.swift`.

## Decisions to confirm before you write code

1. **Film Mode "Edit…" reverses a deliberate design choice (A8).** `LauncherViewModel.disableFilmMode()` says "strictly binary… no separate re-edit affordance". Reasons to give the user: to fix a typo in year or month, the user must turn the switch off, turn it on, and type year and month again. Also, the only sign of Film Mode is 12-pt gray text. *Recommendation:* add **Edit…**. It opens the sheet with the *current* values. Keep the switch for on and off. Other option: keep it binary and make the active state louder.
2. **One merged route panel, or two cards?** *Recommendation:* one panel with two rows (Source, Destination) joined by a connector. Use the route visuals of the importing screen. Then setup, importing, and complete look like the same object. Other option: keep two cards and make them quieter.
3. **The camera inventory "Name…" link (A7)** needs a Settings tab-selection binding. It belongs to **S5**. S1 only restyles the row (monospaced folder name). Confirm the split.
4. **Window sizing spike (1.5).** Do you accept a fixed fallback if removing the hack fails? *Recommendation:* yes. Try native `.windowResizability(.contentSize)` first. If any state clips or jumps, keep a fixed window size and scroll long lists inside.
5. **How loud is the Film-Mode-on row, and what does it start with?** *Recommendation:* tint it with the info tone (accent) and add the film icon. Use one line that starts with the *film* camera: `Film Mode — shot on Pentax K1000 · Kodak Gold 200 · Sep 1998  [Edit…]`. Leave out the stock if it is blank. The `?` help text states the purpose in the user's words (see 1.3).

## Tickets

### UI-1.1 — `RoutePanel` in setup
- Add an editable route panel. It has two rows. Each row has a tile, a title, a path or placeholder, and a **Choose/Change** button. A connector joins the rows.
- The destination row has the free-space line (`viewModel.destinationFreeSpaceRowText`). When free space blocks the import, it also has the red space notice (`destinationSpaceWarningText`). Put the **Import Anyway** action (`acceptDestinationSpaceOverride`) inside the notice as a real small button (A10).
- Keep these: drag and drop on each row with the highlight ring (`onDropURLs: acceptDroppedSource/Destination`, `isEnabled = !isRunning`), the `LauncherFolderDropResolver` logic, and `pickSourcePath`/`pickDestinationPath`.
- Tiles use the accent color (S0 tokens). Make the surface quieter: remove the shadow. Use one fill and a hairline stroke.
- Acceptance: ☐ choose, change, and drop work for source and destination ☐ free space shows under the destination ☐ the Scan Preview no longer mentions the destination ☐ it looks correct in light and dark.

### UI-1.2 — Scan Preview
- Use one `Grid`: Photos · Videos · (Audio if more than 0) · Cameras · Size. Put Dates in the same grid, not in a full-width row below.
- Make the camera list size to its content, with a maximum height. Remove the fixed 80 pt list height (`cameraInventoryMaxHeight`) and the 132 pt `emptyInventoryCardMinHeight`. Show each camera as `folder-name … count`. Use a monospaced font for the folder name. It is the folder that the app will create.
- The empty state is a visible **drop zone** ("Drop a card or folder here, or Choose…") that calls `acceptDroppedSource`. Show one message only. **Do not change the view-model strings.** Tests pin `statusMessage`. Stop *showing* the duplicates in the view.
- Show the scan notices (`scanErrorText`, `scanWarningText`, `unsortedWarningText`) with `NoticeBanner` (S0).
- Acceptance: ☐ no empty gap under a 1-camera list ☐ the empty state shows one instruction ☐ drop works ☐ the scanning spinner stays.

### UI-1.3 — Film Mode row (needs decision 1)
- Off: a switch, "Film Mode", and the `?` help. Behavior does not change: turning the switch on opens the sheet. Cancel and Esc leave it off. Write the help text with the purpose first. It replaces the `explanation` string in `LauncherFilmModeToggleRow.swift:13`: *"Scanned film carries the EXIF of whatever digitized it. Film Mode records the camera and film you actually shot on, and files the photos under the month you shot them."* Use `AppBrand.name` if the app name appears.
- On: a tinted summary row (decision 5, "shot on <camera> · <stock> · <Mon YYYY>") with **Edit…**.
- `LauncherFilmModeSheet` gets an `editing: FilmModeOverride?` init parameter. It fills *every* field, including year, month, shot-at-ISO, and notes. When `editing == nil`, keep today's fill-from-history rules exactly. The code never fills shot-at-ISO and development notes.
- **Cancel while editing must not turn Film Mode off.** Today `cancel()` calls `viewModel.disableFilmMode()`. That would drop the saved roll. Only the switch turns it off.
- Update the doc comment of `disableFilmMode()`.
- Tests: add a view-model unit test. `applyFilmMode` called two times replaces the configuration. S2's `FilmModeDraft` tests cover the fill mapping.
- Acceptance: ☐ after Apply, the summary shows month, year, camera (and stock) ☐ Edit… opens the sheet with the saved values; Apply replaces them; Cancel keeps them ☐ the switch off clears them ☐ "Film Mode resets when a new import starts" (`importAnotherCard`) still works.

### UI-1.4 — Import button and status line
- Replace the two button blocks (`LauncherContentView.swift:136-156`) with one `Button`. Use `.borderedProminent`, `.controlSize(.large)`, `.disabled(!viewModel.isImportReady)`, and `.keyboardShortcut(.defaultAction)`.
- Check each place that shows `statusMessage` (`LauncherContentView.swift:128-133`). Show it only when it adds information that the screen does not show already (scan errors, space notice, empty-state text).
- Acceptance: ☐ Return starts the import when it is ready ☐ the disabled state is clear ☐ no sentence shows twice on the screen.

### UI-1.5 — Window sizing spike (separate commit; easy to revert)
- In `LauncherContentView.swift`, remove `LauncherWindowAccessor`, `LauncherContentHeightPreferenceKey`, `measuredContentHeight`, `configureWindow`, and the `window.setContentSize` calls. Keep `.frame(minWidth:idealWidth:)` and `.windowResizability(.contentSize)`. Remove the fixed-height members of `LauncherWindowMetrics`. Replace `testLauncherWindowMetricsKeepSetupStateTallEnoughForScanResults` (`LauncherCoreParserStatusTests.swift:396`) with a width-only test, or delete it.
- Check every state at the default size: setup empty, scanned, notices; importing; complete; complete with warnings; failure; Film sheet.
- Acceptance: ☐ no content is clipped in any state ☐ no jump or flicker when the state changes ☐ the minimum width holds. If one is not met, revert the commit of this ticket and keep a fixed-size window. Write the result here.

## Result (2026-10-04)

Tickets 1.1 to 1.5 are committed, one commit each. `swift test` and `scripts/run-e2e-tests.sh` pass.
The assistant cannot drive the app. No screenshots were taken. The owner checks these by eye with `scripts/run-dev-app.sh`:
- Setup states: empty (drop zone), SD_CARD1, SD_CARD2, notices, low free space with **Import Anyway**.
- Film Mode: on, **Edit…** shows the saved values, Cancel keeps the roll, the switch off clears it.
- Light and dark appearance, and a non-blue accent color.
- **Ticket 1.5 acceptance:** no clipping and no jump in any state (setup, importing, complete, failure, Film sheet). If one fails, revert the 1.5 commit and keep a fixed window size.
- Before a release: `scripts/release-app-smoke-test.sh --with-launcher-check` (AGENTS.md).

## Out of scope

The importing, complete, and failure screens (S3). The layout inside the Film Mode sheet (S2). Settings (S5). The accessibility sweep (S6). The camera "Name…" link (S5).

## Verification

`swift build` · `swift test` · `scripts/run-dev-app.sh`.
- Check all setup states in light and dark with SD_CARD1 and SD_CARD2.
- Check with a non-blue accent color.
- Try drag and drop on both rows and on the empty Scan Preview.
- Save the `after/` screenshots.
- Before a release that includes this story, run `scripts/release-app-smoke-test.sh --with-launcher-check` (AGENTS.md).

## Spec check

ROL-6 §3 (no behavior change; the Film Mode EXIF exception is why the on-state must be clear), §4 (path wording does not change), §6 (camera labels are folder names).

## Screenshot evidence (2026-10-05)

The owner screenshots of the setup screen (light and dark, with `RK_IPHONE` and `RK_DEST`) show:
- Free space ("6,44 GB free") under the destination.
- The Scan Preview with no destination text, and the camera list as a scrolling list.
- The Film Mode switch with a summary row ("shot on … · Mar 1992") and Edit….
- An insufficient-space banner with "Import Anyway", and a disabled Import button.

Still not shown: choose, change and drop for a source; Return to start; Edit… then Cancel; no clipped content in every state.
