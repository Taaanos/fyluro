# UI Overhaul — Story Index

This folder holds the approved UI overhaul plan (first written 2026-10-03).
Each story is self-contained. You can do each story in a new chat that has no memory of the review.
Open the story file. Ask the user the questions in "Decisions to confirm". Then implement.

## Scope

- The overhaul changes the look and layout of the macOS launcher app and the PDF receipt.
- It adds a small set of shared design parts and uses native SwiftUI components.
- It does not change import behavior. Do not change ingest, staging, verification, commit, `.ndjson` receipt events, or the summary JSON.
- The only engine files in scope are the PDF drawing files.
- The macOS minimum version stays 13 (owner decision, 2026-10-04, see "Design language" below). Do not use macOS 14+ APIs without an `#available` fallback and the user's approval.
  These APIs work on macOS 13: `Form` with `.formStyle(.grouped)`, `LabeledContent`, `Grid`, `ViewThatFits`.

## Core diagnosis

The UI grew one feature at a time, with no shared system. Each commit in `git log -- Sources/rollkeepLauncher` added one more thing.
Symptoms:
- Four separate notice-box implementations.
- A hard-coded `.blue` accent.
- A window that the code resizes by hand.
- An 11-field Film Mode form.
- A PDF whose numbers do not add up.

The fix is a small design system and native controls. It is not a new coat of paint.

## Decisions already made (do not ask again)

| Decision | Answer |
|---|---|
| Keep and restyle | The Source→Destination route, the icon tiles, and the Scan Preview stats. The Film Mode switch is not protected. |
| PDF appendix | Exceptions-first. List errors and renamed files in full. Show a "where files landed" folder table. Show duplicates as one count. The full per-file list stays in the `.ndjson`. |
| Setup-mistake prevention (preflight sheet, readiness checklist, layout summary) | Deferred. It is out of scope for every story. The old plan file is deleted. Git history has it. |
| Film Mode purpose (user, 2026-10-04) | Film Mode has one valid purpose: record metadata for film photos. This means the camera and film that made the shots, not the scanner or camera that digitized them. The UI must say this. Put the film camera first. Keep "shot on" separate from "digitized with". Film Mode is not a risky advanced override. The UI shows it clearly so the user can trust that the right camera is recorded. The receipt (PDF) must show it too. |
| Scope | Visual and structural only. |
| Learning goal | The user is new to UI/UX and wants to learn. Give the principle for each change. Explain the trade-offs before you ask for a decision. |

## Design language (user, 2026-10-04)

Every story follows these visual rules:
- One home for each visual decision. Use one token home (opacity, glass tint, secondary white, warning and error colors) and one modifier for each surface. This matches S0 tokens.
- System accent (`Color.accentColor`), not a hard-coded blue. Warning and reject colors are named tokens, chosen by measured contrast. Text keeps 4.5:1. A mark keeps 3:1.
- Liquid Glass surfaces (`.glassEffect`) with `reduceMotion` fallbacks for the transitions.
- Corners that match the window (`Plate.windowRadius`, concentric radii).
- Each design decision has a story ID, a report, and a repeatable check (`make contrast`).

**Decision (user, 2026-10-04): keep macOS 13 as the minimum.** The owner first chose to raise it, then reversed the choice. Older Macs stay supported.
Use one token home, system accent, named warning and error colors, measured contrast, and Reduce Motion handling.
Liquid Glass (`.glassEffect`) does not exist on macOS 13. Use it in at most one or two places. Put the `#available` check inside the shared `Surface` component, with a material or plain-fill fallback. If no place needs glass, skip it. Decide again at S6, when the whole UI is visible.
Reason: the overhaul is mostly structure (route panel, Form-based sheets, stat grid, action bar). That structure works on macOS 13. Only the surface material depends on the OS version. Raising the minimum later is cheap (delete one branch). Lowering it later is not.

## Principles

Use these when you explain a change.

1. **Hierarchy.** Each screen has one clear main element. Make it with size, weight, and position. Do not give every element the same box, border, and tint.
2. **Native first.** System controls and semantic colors (`Color.accentColor`, `.primary`, `.secondary`, materials) follow dark mode, light mode, the user's accent color, and accessibility settings. They also follow future OS design updates. Hand-drawn cards do not.
3. **Proximity.** Put information next to the thing it describes.
4. **Show state where the user can see and edit it.** This is most important for anything that changes the user's files.
5. **Color carries meaning.** Green means success. Red means error. Amber means "needs attention". Do not use color as decoration or for neutral facts.
6. **Consistency.** The same job has the same look and position.
7. **Say it once.** Give one message for each situation.

## Order and dependencies

```
S0 Foundations -> S1 Main window -> S3 Import states -> S2 Film Mode sheet -> S5 Settings -> S6 Accessibility and finish

S4 PDF receipt   (independent of S0-S3; do it first as a low-risk start, or at any time)
```

Recommended order: **S0, S1, S3, S2, S4, S5, S6.**
Do S0, S1, and S3 first. Then setup, importing, and complete share one visual system.
The story numbers are fixed IDs from the original plan. They are not the order.
Merge each story to `main` before you start a story that depends on it.

| Story | File | Depends on | Status |
|---|---|---|---|
| S0 Foundations | [story-0-foundations.md](story-0-foundations.md) | — | Done |
| S1 Main window | [story-1-main-window.md](story-1-main-window.md) | S0 | Done |
| S3 Importing, Complete, Failure | [story-3-import-states.md](story-3-import-states.md) | S0, S1 | Done. Some visual checks deferred (see story) |
| S2 Film Mode sheet | [story-2-film-mode-sheet.md](story-2-film-mode-sheet.md) | S0 and S1 ticket 1.3 (adds the `editing:` init of the sheet) | Done |
| S4 PDF receipt | [story-4-pdf-receipt.md](story-4-pdf-receipt.md) | — | Done |
| S5 Settings and Camera Labels | [story-5-settings.md](story-5-settings.md) | S0 | Done |
| S6 Accessibility and finish | [story-6-accessibility-finish.md](story-6-accessibility-finish.md) | S0–S5 | Not started |

[findings.md](findings.md) lists the findings. The stories refer to them by ID (for example A8, F2).

## Rules for every story

**Before you write code**
1. Read `AGENTS.md`, `docs/ROL-6-spec-and-invariants.md`, this README, the story file, and the related rows of [findings.md](findings.md).
2. Do the spec check. Each story lists the sections. If anything conflicts with the spec, stop and ask the user.
3. Ask the user each question in "Decisions to confirm". Give your recommendation first. Give one short explanation of the principle. Wait for the answers. Write the answers in a `## Confirmed decisions` section at the top of the story file. Then later chats can see them.
4. Run `git status`. The working tree can hold the user's own unrelated work (icon assets, packaging scripts, document cleanup). Create the branch `ui/s<N>-<slug>` from an up-to-date `main`. Stage only the files you changed. Never use `git add -A`.

**While you write code**
- Use the smallest safe step. One ticket is one commit.
- Use a conventional-commit prefix (`feat:`, `refactor:`, `fix:`, `test:`, `docs:`). Name the story and ticket in the message. Explain the scope and intent.
- Remove duplication before you add an abstraction. Build a shared component in the story that first needs it. S0 builds only what S0 uses at once.
- Never edit ingest, staging, verify, commit, or receipt-event code.
  The only non-UI files in scope are `Sources/RollKeepEngine/PDFReceipt*.swift` and `Sources/RollKeepCore/PDFReceiptReportBuilder.swift` (S4 only), and `AppBrand` (S0).

**Gate for every ticket**
- `swift build` has no errors and no new warnings. `swift test` passes.
  The launcher tests drive the view-model in-process. View-only changes must not break them. Update tests on purpose where a story says it changes pinned behavior.
- For visual changes: build and start the app with `scripts/run-dev-app.sh`. Look at it in light and dark appearance.
  Save before and after screenshots in `docs/ui-overhaul/before/` and `docs/ui-overhaul/after/`. Name them `<state>-<light|dark>.png`. Ticket S0.1 creates the baseline.
- A story is done when all tickets are merged, the acceptance boxes are checked, and the user has tried the build and approved it.
- Release gate: before you ship a release that includes S1, run `scripts/release-app-smoke-test.sh --with-launcher-check` by hand (AGENTS.md). S1 changes `LauncherContentView.swift` near the `.task` block.

**Wrap-up message for each story.** State what changed. State the one principle to remember. Add the before and after screenshots. Add a short **Spec check** note that lists the ROL-6 sections you used.

## Changes since the plan was written

- `AGENTS.md` no longer requires a CLI run for each ticket or a `dist/RollKeep.app` build for each story.
  These stories use `swift test` as the gate and `scripts/run-dev-app.sh` for visual review.
  Story 4 also makes a real PDF with the CLI (`--pdf`). This is the only way to get a PDF to inspect. If the user adds the old rules again, follow them.
- **A8 changed.** The missing Film Mode "edit" path is a documented design choice. The `disableFilmMode()` doc comment says "strictly binary… no separate re-edit affordance". Commit `e55cdc5` added it with Film Mode. Ticket S1.3 reverses it. It needs an explicit user decision.
- **S0.3 is smaller.** Components are built where they are first used: `ResultActionBar` in S3 and the editable `RoutePanel` in S1.
- **The A7 "Name…" link** needs a Settings tab-selection binding. It moved to S5.
- **F6 sidecar label.** `per_file_outcomes` has no sidecar flag. It has only `media_type`. S4 must derive the label or add a field. This is a decision for S4.
- **Completion stats (S3).** `IngestCounts` already has photos, videos, audios, verified, and conflictsRenamed. The work is in the launcher view-model only. No engine work is needed.
- **Known issue KI-2** (`docs/known-issues.md`): a run can show `VERIFIED` while skipped files stay on the card. The owner deferred it. Story S3 decision 6 says what to do.

## Parked (not in any story)

- Setup-mistake prevention: preflight confirmation, readiness checklist, layout summary on the main screen.
- "Eject card" after a verified import. It fits the invariants, but it is a feature, not polish.
- Why `.xmp` sidecars import again as `-1.xmp` on a second run. Maybe the source sidecars changed after the first import. This is a behavior question. The S4 PDF will explain it.
- App icon and visual identity. Wait for the rebrand (one Greek word, not chosen yet).
