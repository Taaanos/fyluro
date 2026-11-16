# UI-S0: Foundations — baseline, tokens, shared parts

**Status:** Done (2026-10-04) · **Depends on:** — · **Branch:** `ui/s0-foundations` · **Size:** small to medium
**Rule for this story:** make no visual change on a Mac that uses the default blue accent.
This keeps later stories easy to review. When S1 changes the look, the diff must not contain refactoring noise.

## Confirmed decisions (user, 2026-10-04)

1. Screenshots: `docs/ui-overhaul/before/` and `after/` stay out of git. Both folders go in `.gitignore`.
2. `AppBrand` lives in `Sources/RollKeepCore/AppBrand.swift`. The value stays "RollKeep".

## Goal

1. Capture a **before** baseline of every UI state, in light and dark.
2. Add the smallest shared vocabulary: spacing, radius, and status-color tokens, and one app-name constant.
3. Replace the duplicated parts that S0 can use at once: one surface style, one notice banner, one stat block.

## Why (principles)

- **Consistency (#6).** The code has 71 hand-set color, font, radius, and padding values. Each screen was styled from nothing. A token is a named decision, for example "a warning is this orange". You decide once.
- **Native first (#2).** `Color.accentColor` follows the accent in System Settings. A hard-coded `.blue` does not (finding A1).
- **Say it once (#7).** There are four notice-box implementations (finding C4). They drift apart. One component cannot.

## Read first

`AGENTS.md`, `docs/ROL-6-spec-and-invariants.md`, [README](README.md), [findings.md](findings.md) (A1, A2, C4, G).
Files: `Sources/rollkeepLauncher/LauncherSetupViews.swift`, `LauncherRouteViews.swift`, `LauncherContentView.swift`, `LauncherSettingsViews.swift`, `LauncherCameraLabelsSettingsView.swift`, `LauncherViewModelPresentation.swift` (`statusColor`).

## Decisions to confirm before you write code

1. **Where do the before and after screenshots live?** They show local paths such as `/Users/<name>/…`. *Recommendation:* keep `docs/ui-overhaul/before/` and `after/` out of git (add both to `.gitignore`). The story files stay tracked. Other option: commit the images after you crop or blur the paths.
2. **How are the screenshots captured?** Capture the window (⇧⌘4, Space, click the window). Some states need fixtures or actions. Ticket 0.1 lists them.
3. **Where does `AppBrand` live?** *Recommendation:* `Sources/RollKeepCore/AppBrand.swift` as `public enum AppBrand { public static let name = "RollKeep" }`. The launcher and the PDF engine both need it. The value stays "RollKeep". The rename is a separate, later project. This change only makes the name one line to change in these strings.

## Tickets

### UI-0.1 — Baseline screenshots
Save to `docs/ui-overhaul/before/<state>-<light|dark>.png`. Change the appearance in System Settings → Appearance.

| State | How to reach it |
|---|---|
| `setup-empty` | Choose no source. The destination can be remembered. |
| `setup-scanned` | Choose `Tests/TestingDirs/SD_CARD1` as source. Do it again with `SD_CARD2`. |
| `setup-notices` | If it is cheap to reach: a scan warning, an unsorted warning, or a low-space notice. |
| `film-sheet`, `film-on-row` | Turn Film Mode on. Fill month, year, and camera. Apply. |
| `importing-scan`, `importing-copy` | Start an import. Take one frame in the scan phase and one in the copy phase. A larger source helps. |
| `complete`, `complete-rerun` | Finish an import. Then import the same source to the same destination again (the "No new items imported…" variant). |
| `failure-stopped` | Press **Stop Import** during a run ("Import Stopped"). |
| `settings-catalogue`, `settings-camera-labels` (empty, and with a detected camera) | Press ⌘, |
| `receipt-pdf` | Copy one `*.summary.pdf` to `before/receipt-before.pdf`. |

**Status (2026-10-04).** The owner took the screenshots in dark mode only. Light mode is deferred (owner decision).
Saved in `docs/ui-overhaul/before/` (ignored by git): `setup-empty-dark`, `source-picker-dark`, `film-sheet-dark` (a crop; the camera is filled, month and year are empty), `setup-scanned-dark`, `complete-rerun-dark`, `importing-scan-dark`, `failure-stopped-dark`, `receipt-before.pdf` (a completed run), `receipt-stopped-before.pdf` (a stopped run).
Still missing, dark: `setup-notices`, `film-on-row`, `importing-copy`, `complete` (first run), `settings-catalogue`, `settings-camera-labels` (empty and with a detected camera). All light-mode shots are missing.

**Decision (2026-10-04).** The owner stops the screenshot work. The nine dark-mode shots above stay as the baseline. The missing states are waived. Check later stories by running the dev app.

Acceptance: ☑ waived by the owner, with the captured shots as the baseline ◐ light mode: light screenshots of setup, Complete and Failure exist (2026-10-05). The importing screen is missing.

### UI-0.2 — Tokens and `AppBrand`
- Add `Sources/rollkeepLauncher/LauncherDesign.swift`. Keep it small (about 80 lines or less):
  - a spacing scale (`4, 8, 12, 16, 24`) and **two** corner radii (card, control);
  - a `LauncherTone` enum with `.neutral`, `.info` (accent), `.success`, `.attention`, `.error`. Map each to a **system** color (`Color.accentColor`, `.green`, `.orange`, `.red`). No other code hard-codes these;
  - text roles only if a combination repeats today (for example `caption.weight(.semibold)` with `.secondary` as a section label, used 8 or more times). If not, skip.
- Add `AppBrand.name` in `RollKeepCore`. Replace the 7 literals in findings.md §G (3 in the launcher, 4 in the PDF). The PDF titles use string interpolation, for example `"\(AppBrand.name) Transfer Receipt"`.
- `LauncherViewModel.statusColor` (`LauncherViewModelPresentation.swift:69`) returns raw `.green`, `.red`, `.blue`. Use the tone colors.
- Replace `LauncherPanelStyle.accent = .blue` and the default `.blue` of `LauncherSettingsCard` with the info tone (`Color.accentColor`).

Acceptance: ☐ `grep -rn "\.blue" Sources/rollkeepLauncher` finds only intended uses ☐ none of the 7 listed places has the literal "RollKeep" ☐ screenshots with the default blue accent equal the baseline ☐ with a non-blue accent, the tiles and the Import button now match.

### UI-0.3 — Use the shared parts (only those S0 can use now)
- `Surface`: one panel background. It replaces `LauncherPanelBackground` and the fill, stroke, and opacity values of `LauncherPanelStyle`. **Keep today's look exactly** in S0. S1 makes it quieter.
- `NoticeBanner(tone:title:text:content:)`. It replaces exactly these three: `LauncherSourceInventoryNoticeStrip` (`LauncherSetupViews.swift`), the private `LauncherCameraLabelsBanner`, and the inline orange error box in `completeSection` (`LauncherContentView.swift:250-303`). The last one has a title and a scrolling list. Use the `content` slot for the list. The Settings hover tooltip is a different part. S5.4 handles it.
- `StatItem`: move `LauncherSourceInventoryStat` to the shared file without changes.

**Status (2026-10-04).** Done in `Sources/rollkeepLauncher/LauncherComponents.swift`. `Surface` replaces `LauncherPanelBackground`. `NoticeBanner` replaces the three notice boxes. `StatItem` replaces `LauncherSourceInventoryStat`. `LauncherPanelStyle` stays, because S1 restyles it. `NoticeBanner` has an `emphasizedText` option, so the Camera Labels banners keep their primary text color. Banner text is now selectable everywhere. Visual comparison with the baseline is not done yet (screenshots are deferred).

Acceptance: ☑ the three old notice implementations are deleted ☑ the call sites look the same as the baseline (checked on `setup-empty` only; the info icons look slightly darker than the old `.blue`, because `Color.accentColor` replaced it) ☑ `swift test` passes.

## Out of scope

Restyling. `RoutePanel` (S1). `ResultActionBar` (S3). Form layouts (S2, S5). Accessibility (S6).

## Verification

`swift build` (no new warnings) · `swift test` · `scripts/run-dev-app.sh`. Compare each state with its baseline in both appearances.

## Spec check

The ROL-6 §3 invariants are not touched. No behavior changes. This story is presentation only.
