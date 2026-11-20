# UI-S5: Settings and Camera Labels

**Status:** Done (2026-10-05) · **Depends on:** S0 merged (tokens, `NoticeBanner`) · **Branch:** `ui/s5-settings` · **Size:** medium
**Warning:** the review used the code only for the Settings window. Capture it (S0.1) and look at it before you design.

## Confirmed decisions

Owner answers, 2026-10-05. All follow the recommendations.
1. Path scheme: keep Apply and Reset. Show the warning as persistent text.
2. Words: Catalogue tab becomes Library. "Catalogue Scheme" becomes Folder Layout. "Render Paths" becomes Preview. Remove the en-space tab padding.
3. Camera Labels: grid with Camera code, Name, Folder preview. "On the current card" first, saved labels next, add row last.
4. Ticket 5.5 (the "Name…" action) was built, then removed the same day. Owner: naming a camera should rarely be a user task, so a link on every row is noise. Finding A7 stays open. A better fix is for the app to name cameras itself (a decision for a later story).

## Outcome (2026-10-05)

Built: tickets 5.1 to 5.4. Ticket 5.5 was built and removed (see decision 4). Added by the owner during review: no rescan after a label save (the scan preview stays what the card had at scan time), shared names allowed with a visible note (ROL-6 section 6, "Shared names"), and a Scan Preview row that shows `original (folder)` for labels the scan applied.
Not done: listing every camera model code on the card. It needs a change in the engine (`CameraLabeler.swift`). It was built and reverted. See KI-6.
Open: the owner may remove the camera label feature. Each pane sets its own height because a grouped Form has no height of its own on macOS. The numbers are estimates.
No after screenshots were saved. The owner checked the build by hand in dark appearance.

## Goal

Settings that look and work like macOS Settings: grouped forms that size to their content, one save model for the whole window, plain words, and no content that shows only on hover.
Camera Labels uses native layout, not column math by hand. It also gets the entry point from the main window (finding A7).

## Why (principles)

- **Native first (#2).** `Settings` with `TabView` is correct. The *inside* of each pane uses hand-made cards and tricks: en-space padding to fake a click area, magic offsets (`codeColumnWidth + 8 + 12 + 8`), and a fixed 560×640 frame for every pane. A grouped `Form` gives all of that and follows OS changes.
- **Consistency (#6).** The Catalogue pane uses draft → **Apply** → auto-dismiss. Camera Labels in the same window saves while the user types.
- **Plain words (#7).** "Catalogue" is British English, and ROL-6 says *catalog* or *library*. "Render Paths" is jargon.
- **Accessibility.** Content that shows only on hover (the ⚠️ tooltip) is not available to keyboard and VoiceOver users (D).

## Read first

`AGENTS.md`, `docs/ROL-6-spec-and-invariants.md` (§3 path-strategy snapshot lock, §4 path scheme, §6 **User camera catalog**: storage, ownership, unreadable-file rules, export and import), [README](README.md), [findings.md](findings.md) E, D.
Files:
- `LauncherSettingsViews.swift` (root `TabView`, `LauncherSettingsView`, `LauncherSettingsHoverWarningIndicator`, `LauncherSettingsCard`, `LauncherSettingsPreviewPathCard`).
- `LauncherCameraLabelsSettingsView.swift`, `LauncherCameraCatalogStore.swift`.
- `LauncherPathSchemeSettingsStore.swift` (`hasPendingChanges`, `pendingWarningMessages`, `applyDraft`).
- `FyluroLauncherApp.swift` (`LauncherSettingsWindowMetrics`).

Tests: `LauncherCorePathSchemeSettingsTests.swift`, `LauncherCameraCatalogStoreTests.swift`. Store behavior must not change.

## Decisions to confirm before you write code

1. **Apply or instant for the path scheme (E).** The app saves the scheme at the start of a run (ROL-6 §3). A change can never affect a running import. So instant apply is safe, and macOS Settings works this way. But `pendingWarningMessages` exist for a reason: a layout change can split an existing library into two structures. *Recommendation:* keep **Apply and Reset for now** (it protects against an accidental layout change). Make the warning persistent text. Look at the decision again after the user has used S1. Other option: instant apply and a permanent footer "Applies to the next import."
2. **Words.** *Recommendation:* tab "Catalogue" → **Library**. Card "Catalogue Scheme" → **Folder Layout**. "Render Paths" → **Preview**. (ROL-6 uses *catalog placement* and *library*.) Confirm the words.
3. **Tab-title padding trick.** The en-space padding exists because the native toolbar-tab highlight fits the label closely. Remove it and accept the native look, or keep it? *Recommendation:* remove it. If the result looks tight, try a native option before you add any trick again. Ask first.
4. **Camera Labels layout.** *Recommendation:* a `Form` or `Grid` with the columns *Camera code · Name · Folder (monospaced preview)*. Put detected cameras without a label first ("On the current card"). Put saved labels below. Put the add row at the end. Keep: save on blur and Enter, the trash button, the live folder preview, the "same folder as…" warning, and the example row when empty.
5. **Inline "Name…" entry (A7).** The camera inventory row on the main window gets a "Name…" action. It opens Settings on the Camera Labels tab. This needs a tab-selection binding (for example `@AppStorage` or `@SceneStorage` that drives `TabView(selection:)`). On macOS 13, it also needs `NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)`. macOS 14 and later have `SettingsLink`. *Recommendation:* include it as the optional ticket 5.5. Skip it if the macOS 13 path feels like a hack.

## Tickets

### UI-5.1 — Catalog/Library pane as a grouped `Form`
- Replace the card stack with `Form { Section … }` (`.formStyle(.grouped)`). Sections: Folder Layout (the chronological layout `Picker`, "Group by camera", "Split photos into RAW / Non-RAW") and Preview (three sample paths, monospaced, selectable, scroll sideways if long).
- Size to content. Remove the fixed 640 pt height from `LauncherSettingsWindowMetrics`. Keep a sensible fixed width.
- Persistent warning (decision 1): show a `NoticeBanner` when `pendingWarningMessages` is not empty. Keep the `Apply` and `Reset to Default` row.
- Acceptance: ☐ same bindings and store calls ☐ the warning shows without hover ☐ the pane height fits the content in both appearances ☐ `LauncherCorePathSchemeSettingsTests` pass without change.

### UI-5.2 — Camera Labels layout
- Follow decision 4. Remove the magic padding math and `LauncherCameraLabelsMetrics` where the grid makes them unnecessary. Show the banners (`loadWarning`, `recoveryNotice`, `saveError`) with `NoticeBanner`.
- Do not change catalog meaning: ROL-6 §6 (keys normalized to uppercase, ASCII kebab-case folder names, a bad file is moved aside, export and import are app-only).
- Acceptance: ☐ add, edit, delete, and the duplicate-folder warning work ☐ keyboard: the Tab order is code → name → add; Return saves ☐ `LauncherCameraCatalogStoreTests` pass.

### UI-5.3 — Words
- Apply decision 2 to tab titles, card and section titles, subtitles, and help text. Use `grep` for "Catalogue" and "Render" to find all uses. Do **not** rename code symbols.
- Acceptance: ☐ no "Catalogue" or "Render Paths" in user-visible strings ☐ the wording matches ROL-6 where it names the same thing.

### UI-5.4 — Replace the hover tooltip (optional; skip if the inline warning of 5.1 covers it)
- After the inline `NoticeBanner` works, delete `LauncherSettingsHoverWarningIndicator` and its hover timers (about 60 lines).

### UI-5.5 — "Name…" entry from the main window (optional; decision 5)
- Add the tab-selection binding and the action. Connect it from the camera inventory row of S1.

## Out of scope

Changes to catalog storage or format, export and import behavior, or the meaning of the path scheme. New settings.

## Verification

`swift build` · `swift test` · `scripts/run-dev-app.sh`, then press ⌘, in light and dark.
- Change each setting and watch the preview.
- Cause the pending-change warning.
- Add, edit, and remove labels, including a duplicate folder and an invalid name.
- Set `FYLURO_CAMERA_CATALOG_PATH` to a scratch file so the real catalog stays untouched.
- Save `after/settings-*.png`.

## Spec check

ROL-6 §3 (snapshot lock: why instant apply is safe), §4 (scheme options and preview strings), §6 (camera catalog rules; the app is the only writer; wording of the unreadable-file banner).
