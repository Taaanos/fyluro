# UI-S3: Importing, Complete, and Failure screens

**Status:** Tickets 3.1–3.3 built and committed. Owner review partly done. Four checks are deferred. · **Depends on:** S0, S1 merged (it needs the route panel) · **Branch:** `ui/s3-import-states` · **Size:** medium

## Confirmed decisions (owner, 2026-10-04)

1. Main action on Complete: **Open New Folders in Finder**. Import Another Card is secondary. View Receipt and Open Source are low-emphasis.
2. Failure screen: **add** a low-emphasis Show Staging Folder (UI wiring only).
3. The word "Verified": **no**. Keep today's wording. Do not add "Verified" or "N of N files verified" to the screen. Do not add a Verified stat tile. KI-2 stays deferred.
4. Stats grid: **full set** without the Verified tile: Added to library, Already in library, Size, Photos/Videos/Audio (only if more than 0), Camera(s), Renamed (only if more than 0), Elapsed time.
5. Words: **S4 vocabulary** (Added to library, Already in library, Renamed).
6. Skipped files: deferred (KI-2), as written below.

## Result and open checks (2026-10-05)

Tickets 3.1, 3.2 and 3.3 are committed on `ui/s3-import-states`. `swift test` and `scripts/run-e2e-tests.sh` pass.
The owner checked these in the dev app (dark appearance): the importing screen, a clean Complete screen, and an idempotent rerun.
That review found two problems. Both are fixed: the missing Cameras tile, and the uneven action bar.

Deferred by the owner until computer use is available. Status after the owner screenshots of 2026-10-05:
- ☐ A stopped import (neutral pause mark). No screenshot yet.
- ☑ A failure screen (red cross). Seen in dark and light (`RK_IPHONE` into `RK_TINY`). "Show Staging Folder" was disabled, and this is correct: the run failed before the copy phase, so no staging folder existed on `RK_TINY`.
- ☐ Reduce Motion on (still arrow while importing). No screenshot yet.
- ◐ Light appearance: Complete and Failure seen in light. The importing screen is still open.
- ☑ The action bar wraps at the minimum width on the Failure screen. It did wrap, and the result looked uneven. Replaced on 2026-10-05, see "Owner review, round 2".
- ☑ The Size tile equals the PDF `bytes_processed`. Size tile: 317,6 MB. `SUMMARY.bytes_processed`: 317,589,431 bytes. They agree for the same run.
- ☑ Save the `after/` screenshots (local folder, git ignores it).

### Owner review, round 2 (2026-10-05)

Findings from the screenshots, and what changed:
- The window got smaller on the Failure screen (about 285 pt, against 640 pt on setup) and on Complete (about 527 pt). Fix: every state has the same minimum content height (612 pt). The main action sits at the bottom of each state.
- The result buttons looked uneven: two bordered buttons, one gray text button that looked disabled, and the main action alone on a second row. Fix: `ResultActionBar` draws all lesser actions as bordered buttons in one row. It draws the main action as one wide default button below, like Import on setup. The tertiary style is removed.
- The RAW notice said "aren't supported yet". Owner decision: say "are not supported". Changed in the notice and in the Film Mode sheet.
- ☑ Owner screenshots (dark): Complete and Failure both use the 612 pt minimum height, and the bordered buttons are consistent. A first version clipped the Import button on setup with the out-of-space banner. Fixed in `669fe65`. A new screenshot shows the whole button, and the window grows to fit the banner.
- ☑ The Complete screen with Film Mode shows the Film Mode line and the new RAW wording.
- Known trade-off: Complete and Failure have an empty area between the content and the buttons. Owner decision (2026-10-05): keep it as it is. The window size stays constant.

## Goal

The three result-side screens use the same visual system as setup:
- the **same route panel** (animated while it runs, static ✓/✗ after),
- a stat-grid **evidence summary** on success,
- one **result action bar** with the same place on success and failure,
- motion that respects Reduce Motion.

## Why (principles)

- **Consistency (#6).** Success puts the actions in a vertical stack. Failure uses a row with the main action on the right. It is the same job in two layouts.
- **Hierarchy (#1).** Four buttons have four widths and four weights (findings C1, C2). The visible bug: `.frame(maxWidth: .infinity)` is outside the bordered button, so the bezel fits its label. The Import button puts the frame *inside* the label, which is correct.
- **The evidence is the product (C3).** The user checks a copy before formatting the card. The complete screen must *show* what the app verified. "9 items imported" is not enough.
- **Color carries meaning (#5) and accessibility.** A looping animation must stop for people who turned motion off (D).

## Read first

`AGENTS.md`, `docs/ROL-6-spec-and-invariants.md` (§2 outcome and VERIFIED, §8 verification definition, §9 failure rules, §10 summary fields), [README](README.md), [findings.md](findings.md) C1–C4, D, H3, `docs/work/bugs.md` (KI-2).
Files:
- `LauncherContentView.swift` (`importingSection`, `completeSection`, `failureSection`).
- `LauncherRouteViews.swift`.
- `LauncherViewModelPresentation.swift` (`completionItemsText`, `completionOutcomeText`, `failureTitle`, `failureMessage`, `filmModeRawSkipNoticeText`).
- `LauncherViewModelIngest.swift` (`applyFinished`, about lines 150-180; reset at about line 240).
- `LauncherViewModelReceiptPipeline.swift` (a second path that sets `finalizedCommittedCount`, about line 90).
- `Sources/RollKeepEngine/IngestSessionResult.swift` (`IngestCounts`: photos, videos, audios, verified, committed, duplicateNotCopied, conflictsRenamed, errors).

Tests that pin wording: `LauncherCoreViewModelDefaultsActionsTests.swift:142` (`completionItemsText`).

**First, capture the importing and failure screens.** Nobody has reviewed them on screen. The S0.1 baseline must have them. If it does not, take them now and look before you design.

## Decisions to confirm before you write code

1. **Main action on success.** Today "Open New Folders in Finder" is the prominent button. *Recommendation:* keep it as the main action (the user checks what arrived). "Import Another Card" is secondary. "View Receipt" and "Open Source" are low-emphasis links. Other option: make "Import Another Card" the default button for a daily-import workflow.
2. **Staging folder on failure.** `LauncherViewModel.openStagingFolder()` and `canOpenStagingFolder` exist, but **no view uses them**. ROL-6 §2 says a failure reports "receipt path and staging path". *Recommendation:* add a low-emphasis "Show Staging Folder" to the failure action bar (UI wiring only, no behavior change). Other option: leave it.
3. **The word "Verified".** `IngestSessionResult` has no `verifiedOK` field. The app's `.success` state already means ROL-6 §8 "session VERIFIED". *Recommendation:* label the success state **Verified** and show "N of N files verified" from `counts.verified` and `counts.copied`. Confirm that the user wants this word on screen. See decision 6 first.
4. **Which stats the summary shows** (S1's `StatItem` grid). *Recommendation:* Added to library · Already in library · Verified · Size · Photos/Videos/Audio (only if more than 0) · Camera(s) · Renamed (only if more than 0) · Elapsed time.
5. **Same words as the PDF (S4).** Use the S4 vocabulary (*Added to library, Already in library, Renamed*). Then the screen and the receipt agree.
6. **Skipped files and the Verified label — DEFERRED (owner decision, 2026-10-04).** A run can end `VERIFIED` while files stay on the card that were not ingested (an unreadable file, a skipped symbolic link). The user could format the card and believe that every file is copied. The owner chose not to change the label or the summary now. Do not add a "N files were not copied" line or change the label in this story. Track it as KI-2 in `docs/work/bugs.md`. Decision 3 (the word "Verified") stays as written; the owner must reopen KI-2 before the label ships if this gap is still open.

## Owner note: candidate counts (2026-10-04)

The importing screen can show a title count that differs from the body count (for example "Importing 230 items..." and "2259 import candidates"). The owner says optimizations for videos probably cause this, and that the optimizations are important. Do not change how the counts are computed. Ticket 3.1 may change only how they look.

## Tickets

### UI-3.1 — Route panel in all states, and Reduce Motion
- Importing: use the same `RoutePanel` as in setup (S1), not editable, with the arrow animated. Complete: static, with a ✓ (success tone; warning tone if `hasRecordedErrors`). Failure: static ✗ (error tone), or neutral if the user stopped the run.
- `LauncherFlowArrow`: read `@Environment(\.accessibilityReduceMotion)`. When it is true, show a static arrow and a static "in progress" cue. Do not repeat the animation.
- Text order while importing: title → progress bar → one main line (items copied) → one secondary line (ETA or phase) → current file (caption, truncated in the middle). Keep every existing computed string.
- Acceptance: ☐ the route shows in all three states ☐ with Reduce Motion on, no animation loops ☐ the progress math (`LauncherImportPresentation`) is unchanged.

### UI-3.2 — Evidence summary on Complete
- Add the counts you need from `IngestCounts` as new `@Published finalized…` properties **in both** `applyFinished` and the receipt-pipeline fallback path. Reset them where `finalizedCommittedCount` is reset. Add tests in `LauncherCoreViewModelBehaviorTests`.
- Replace the single card of text with a `StatItem` grid (decision 4). Keep the existing items and outcome sentences as headline and sub-headline (tests pin the strings).
- **Film Mode line (finding H3).** When Film Mode was on, show it on the summary: `Film Mode — recorded as shot on <camera> · <stock> · <Mon YYYY>`. Read it from `viewModel.filmModeConfiguration`. It is still set at completion. Only `importAnotherCard` resets it. The user must see, at completion, which camera went into the photo metadata.
- Show warnings (`completionWarningEntries`) and the Film Mode RAW notice (`filmModeRawSkipNoticeText`) with `NoticeBanner` from S0. Keep the RAW notice honest about which files kept their original camera metadata (ROL-6 §5 limit). Put it directly under the Film Mode line. Then the two read as one statement.
- Acceptance: ☐ the numbers match the PDF and receipt for the same run (check with the S4 vocabulary) ☐ the idempotent-rerun variant still reads correctly ☐ the warnings list scrolls after 4 rows, as today.

### UI-3.3 — `ResultActionBar` (fixes C1, C2)
- Build one component: secondary and tertiary actions at the left, the main action at the right. Complete and Failure both use it. Each button gets its width from its label (frame *inside* the label). Never put `.frame(maxWidth:)` on the bordered button.
- Complete: the main action follows decision 1. Failure: the main action is Import Another Card (as today). Add Show Staging Folder if decision 2 says so.
- Keyboard: the main action has `.keyboardShortcut(.defaultAction)`.
- Acceptance: ☐ success and failure have the same place and spacing ☐ no uneven button widths ☐ the disabled states stay (`canOpenReceipt`, `canOpenSource`, `canOpenDestination`, `canOpenNewFinalMediaDirectories`).

## Out of scope

PDF content (S4). The Film Mode sheet (S2). The accessibility sweep beyond Reduce Motion (S6). Any new import behavior (for example eject card; it is parked). Any change to the Verified label or the summary for skipped files (KI-2).

## Verification

`swift build` · `swift test` · `scripts/run-dev-app.sh`.
- Run a clean import, a second import to the same destination (idempotent), a stopped import, and (if possible with the e2e fault-injection scripts) a failure.
- Check light and dark.
- Turn on Reduce Motion in System Settings → Accessibility → Display and check the arrow.
- Save the `after/` screenshots.

## Spec check

ROL-6 §2 (VERIFIED and receipt path on success; reason, receipt, and staging path on failure), §8 (VERIFIED definition), §9 (failure rules; the wording must not hide the failure phase or reason), §10 (the counts on screen must equal the summary fields).

## Start prompt

```text
Read AGENTS.md, docs/ROL-6-spec-and-invariants.md, docs/ui-overhaul/README.md, docs/ui-overhaul/findings.md,
docs/work/bugs.md, and docs/ui-overhaul/story-3-import-states.md. Check that S0 and S1 are merged.
I am new to UI/UX. Explain the principle behind each change. First ask me the questions in "Decisions to confirm".
Wait for my answers. Write them in the story file. Then implement ticket by ticket on ui/s3-import-states.
Do the spec check before you write code.
```
