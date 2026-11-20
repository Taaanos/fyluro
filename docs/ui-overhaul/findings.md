# UI Overhaul — Findings

The evidence comes from the review on 2026-10-03. Sources: screenshots (empty setup, Film Mode sheet, scan result, import complete), the receipt PDF `e9813fd6-….summary.pdf`, and the source code.
Line numbers were correct at `main` = `bdc9bc1`. Check them with `grep` before you edit.
**Not yet seen on screen:** the importing screen, the failure screen, both Settings tabs, and light mode.

## A. Main window

| ID | Finding | Evidence | Fix (story) |
|---|---|---|---|
| A1 | The accent is hard-coded blue. The Import button follows the system accent. The two do not match for users with another accent color. | `LauncherSetupViews.swift:13` (`var accent: Color { .blue }`), `LauncherSettingsViews.swift:271`. 27 hard-coded color uses in `Sources/fyluroLauncher`. | Use `Color.accentColor` for tiles. Use semantic colors only for status (S0, S1). |
| A2 | Every block is the same heavy card: fill, tint overlay, stroke, and shadow (4 layers). Nothing leads. | `LauncherPanelBackground`, `LauncherSetupViews.swift:16-32` | Use one quiet surface style. Merge Source and Destination into one route panel (S0, S1). |
| A3 | The route is a good idea, but it shows only during import. Setup shows two unrelated cards. | `LauncherRouteViews.swift` and `setupSection` in `LauncherContentView.swift` | Make the route the spine of the app. Use the same panel in setup (editable), importing (animated), and complete (static ✓) (S1, S3). |
| A4 | "Free Space" describes the destination, but it sits in the Scan Preview of the source. | `LauncherSetupViews.swift:185` | Move it under the destination path (S1). |
| A5 | Space is wasted or uneven. The camera list is fixed at 80 pt even with 1 row. The empty state has a minimum height of 132 pt. Dates and Free Space are outside the 4-column stat grid. | `LauncherWindowMetrics.cameraInventoryMaxHeight`, `emptyInventoryCardMinHeight` | Size to content with a maximum. Use one `Grid` (S1). |
| A6 | The empty state says the same thing 3 times ("Choose source", "Choose a source to preview…", "Choose a readable source to begin."). Drag and drop works, but the user cannot see that it does. | `LauncherSetupViews.swift:249`, `LauncherContentView.swift:128` | Make the empty state a visible drop zone with one message (S1). |
| A7 | The camera shows as the raw `ilce-7cm2`. Nothing says it is the folder name or that the user can rename it. | The catalog ships empty (ROL-6 §6). | Show it as a monospaced folder name (S1). Add a "Name…" link (S5; it needs Settings tab selection). |
| A8 | **The user cannot edit Film Mode after Apply.** The sheet opens only when the switch turns on. Year and month are blank each time. The on-state is 12-pt gray text. A switch that opens a modal is the wrong control. **This is a deliberate design** (`LauncherViewModel.disableFilmMode()` doc comment, commit `e55cdc5`). | `LauncherFilmModeToggleRow.swift:19-21, 60-64`; `LauncherFilmModeSheet.swift:23-24` | Show a tinted summary and an Edit… button when on (S1.3; needs a user decision). |
| A9 | The code sets the window height by hand on each layout pass (`window.setContentSize`, GeometryReader and PreferenceKey, fixed 486/388 pt). The window jumps between states. | `LauncherContentView.swift:358-416`; `FyluroLauncherApp.swift:29-60`; a test pins it: `LauncherCoreParserStatusTests.swift:396` | Spike: use `.windowResizability(.contentSize)`. If it fails, use a fixed size (S1.5). |
| A10 | Two duplicate Import button blocks. No keyboard default. "Import Anyway" looks like plain text. | `LauncherContentView.swift:136-156, 120-126` | Use one button and `.keyboardShortcut(.defaultAction)`. Put the override button inside the notice (S1.4). |

## B. Film Mode sheet

| ID | Finding | Fix (story) |
|---|---|---|
| B1 | A card sits inside a sheet (double container). 11 fields in one column. "(optional)" appears 8 times. Hint text is 11-pt `.tertiary` (low contrast). Four commits each added a field. | Use `Form` with `.grouped` and `LabeledContent`, in 4 sections (S2.1). |
| B2 | Apply is disabled with no reason. | Show the reason (S2.2). |
| B3 | The year is free text with no validation. The engine's `FilmModeOverride` has none too. | Validate a 4-digit year in the UI only (S2.2). |
| B4 | The buttons are at opposite edges. They have no keyboard roles. | Put the pair at the trailing edge. Use `.defaultAction` and `.cancelAction` (S2.3). |

## C. Import complete and failure

| ID | Finding | Evidence | Fix (story) |
|---|---|---|---|
| C1 | Four buttons have four widths. `.frame(maxWidth: .infinity)` is outside the bordered button, so the bezel fits the label. The Import button puts the frame inside the label, which is correct. | `LauncherContentView.swift:310-328` and `:139-141` | S3.3 |
| C2 | Four actions have four visual weights. The failure screen arranges them in a different way. | `completeSection` and `failureSection` | Use one shared `ResultActionBar` (S3.3). |
| C3 | The success card shows only "9 items imported / 41 duplicates skipped / 3s / Receipt saved". The evidence is the product. | `LauncherViewModelPresentation.swift:308-338` | Use a stat-grid summary (S3.2). |
| C4 | There are four notice-box implementations: `LauncherSourceInventoryNoticeStrip`, `LauncherCameraLabelsBanner`, the inline orange box in `completeSection`, and the hover popover. | — | Use one `NoticeBanner` (S0.3). |

## D. Accessibility

- No code checks `accessibilityReduceMotion`. The route arrow loops forever (`LauncherFlowArrow`, 3 s linear). (S3.1, S6)
- No `keyboardShortcut` exists in the launcher. (S1.4, S2.3, S6)
- The icon-only `?` button and the stat blocks have no VoiceOver labels. The Settings warning tooltip shows on hover only. (S6, S5.4)

## E. Settings and Camera Labels (from code only)

- The Catalogue pane uses draft, Apply, and auto-dismiss. Camera Labels in the same window saves at once. This is not consistent (S5.1 decision).
- Tab titles use en-space characters as padding (`LauncherSettingsViews.swift:24`). Every pane has a forced size of 560×640. Column math is by hand (`codeColumnWidth + 8 + 12 + 8`). (S5.1, S5.2)
- Wording: "Catalogue" is British English, and ROL-6 says catalog or library. "Render Paths" is jargon. (S5.3)

## F. PDF receipt (6 pages for 41 files)

| ID | Finding | Evidence | Fix (story) |
|---|---|---|---|
| F1 | **The footer runs off the page. The user never sees "Page N".** The right text starts at `pageWidth − 180`, but the string is "Session <36-char UUID> • Page N". | `PDFReceiptRenderingSupport.swift:195-199` | Right-align with `singleLineWidth` (S4.1). |
| F2 | **The numbers do not add up.** Candidates 41 (media only, `scanSummary.candidates.count`). Copied and Verified 50 (with 9 sidecars). Committed 9 + Duplicates 41 = 50. "Copied 50" next to rows that say "Duplicate — not copied" looks like a contradiction. | `PDFReceiptReportBuilder.swift:177, 232-245` | Use the same words as the app (S4.2). |
| F3 | Color is wrong. Harmless duplicates are amber 41 times. The harmless Conflicts tile is amber. | `fileOutcomeStatus` in `PDFReceiptPageComposerSections.swift:286`; tones in the builder at `:232-245` | Amber means "needs attention" only (S4.2). |
| F4 | The appendix is noise (41 of 50 rows are the same). It has a cap of 80 (`maximumOutcomes = 80`, builder `~:225`). On a big card the cap hides the last files, including late errors. | | Use an exceptions-first appendix (S4.3). |
| F5 | A 60-character shared path prefix repeats 100 times. | | Show the library root once and use relative paths (S4.3). |
| F6 | `.xmp` sidecars show as "PHOTO". `per_file_outcomes` has `media_type` only and no sidecar flag. | `IngestSummaryBuilder.swift:55, 84` | S4.2 (decision: derive, or add a field). |
| F7 | "Run Context" is split. Page 1 has only "Generated" (a copy of the header). Source, Destination, and Path Scheme start page 2 with no heading. The path-scheme string wraps badly, joins two schemes with `;`, and shows `|` as "I". | `contextRows` in the builder `:184-191`; `PDFReceiptReportBuilderTests.testContextRowsAreTrimmedToSixEntries` pins it. | S4.1 |
| F8 | The hero box is about 40 % empty at the bottom (`heroHeight = 138`; text ends near 98). The whole page has a `#F7F9FC` tint to the edge, which uses much ink when printed. | `PDFReceiptPageComposerSections.swift:5-74`; `PDFReceiptPalette.pageBackground` | S4.1 |

## H. The UI does not show the purpose of Film Mode (added 2026-10-04 after user feedback)

Film Mode has one purpose. Photos from film carry the EXIF of the device that digitized them. The user wants the **camera and film that made the shots** in the metadata instead. The UI does not say this.

| ID | Finding | Evidence | Fix (story) |
|---|---|---|---|
| H1 | The field "Camera" is above "Scanner (optional)". It is not clear which device is which. The text is a generic "declare this batch's month, camera, and film". | `LauncherFilmModeSheet.swift:75, 110, 175` | Label by role: **Shot on** (film camera) and **Digitized with** (scanner or copy camera). Write the text with the purpose first (S2.1). |
| H2 | The on-state shows `· Sep 1998 · camera` in 12-pt gray text. The film camera is not the headline. | `LauncherFilmModeToggleRow.swift:60-64` | Start the summary with "Shot on …" (S1.3). |
| H3 | The complete screen does not say that Film Mode was used or which camera was recorded. | `completeSection` | Add a Film Mode line to the summary (S3.2). |
| H4 | **The PDF receipt does not mention Film Mode.** It has no declared camera, film stock, or month and year. The summary JSON already has a full `film_mode` payload (`IngestSummaryBuilder.swift:150-190`: used, year, month, camera, film_stock, iso, lens, shot_at_iso, development_notes, scanner, creator, copyright, exif_applied/skipped counts). | `grep -i film Sources/FyluroCore/PDFReceiptReportBuilder.swift Sources/FyluroEngine/PDF*.swift` finds nothing. | Add a Film Mode block to the receipt header. No summary or engine change is needed (S4.1). |

## G. Cross-cutting

- The app name is a literal in 7 user-visible strings: `LauncherFilmModeSheet.swift:75`, `LauncherFilmModeToggleRow.swift:13`, `LauncherSetupViews.swift:253`, `PDFReceiptPageComposer.swift:127`, `PDFReceiptExporter.swift:83`, `PDFReceiptRenderingSupport.swift:191`, `PDFReceiptPageComposerSections.swift:20`. A rebrand is planned. Use one `AppBrand.name` constant (S0.2).
- `PDFReceiptExporter.buildReportLines` (a plain-text version of the report) has no caller in `Sources/`. Only tests seem to use it. Confirm this before you decide to keep it in sync or remove it.
