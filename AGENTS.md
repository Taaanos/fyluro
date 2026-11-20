# AGENTS.md

This file gives the working rules for people and agents who work on Fyluro.
The product source of truth is `docs/ROL-6-spec-and-invariants.md`.
If this file and the spec disagree, the spec wins. Stop and ask the user.
Architecture direction: Fyluro is app-first. The CLI shares the engine and is a complementary interface. Some features are app-only by design.
Design priority: Data integrity (`I-1` to `I-10`) > storage medium safety and longevity > raw speed (see `docs/ROL-6-spec-and-invariants.md` Section 1).

## Work Loop

Pick the steps that match the task:

### For code or behavior changes
1. Read the applicable sections of `docs/ROL-6-spec-and-invariants.md`.
2. Name the spec sections that apply. If the task conflicts with the spec or an invariant, stop and ask the user.
3. Settle open questions with the user before you write code.
4. If the behavior changes, update the spec first with the user's approval, and update the spec in the same commit.
5. Build the smallest safe change. Add or update unit or e2e tests.
6. Run `swift test` before each commit. Run an e2e test before commit only if you judge the change needs it.
7. If you changed launcher startup, source detection or scan-on-launch code, run `scripts/release-app-smoke-test.sh --version <version> --with-launcher-check` manually.
8. Check the Definition of done below. Include a "Spec check" note in your chat reply, and commit.
9. Run `scripts/run-e2e-tests.sh` once before you push commits to `origin/main`. This is the mandatory baseline verification.

### For tooling, test script, or build changes
1. Settle open questions with the user before you write code.
2. Build the smallest safe change.
3. Run `swift test` or the changed scripts to verify the change.
4. Skip the "Spec check" note if no product spec section applies.
5. Commit with a conventional prefix (`chore:`, `test:`).

### For documentation-only changes
1. Read `docs/ROL-6-spec-and-invariants.md` only if the document describes product behavior.
2. Make the edit in ASD-STE100 style.
3. Skip `swift test` and `scripts/run-e2e-tests.sh`.
4. Summarize and commit.

### For questions, reviews, or investigations
1. Read files and inspect the code.
2. Do not modify files.
3. Do not run build or test commands unless requested.
4. Reply in ASD-STE100 style.

### When to read `docs/work/README.md`
- Read `docs/work/README.md` only when you select work, check for open bugs in the same area, or update ticket status.
- Skip it when the user gives a self-contained task.

## Definition of Done

A code or behavior task is done only when all of these are true:
- [ ] The chat reply has a "Spec check" note that lists the spec sections used.
- [ ] `swift test` passes before each commit.
- [ ] `scripts/run-e2e-tests.sh` passes before you push to `origin/main` (not required on every commit).
- [ ] The change adds no write, delete or overwrite outside I-9.
- [ ] If the behavior changed, the spec changed in the same commit with the user's approval.
- [ ] Launcher startup, source detection or scan-on-launch changes passed `scripts/release-app-smoke-test.sh --version <version> --with-launcher-check` (`Sources/fyluroLauncher/LauncherViewModelActions.swift`, `LauncherVolumeDefaults.swift`, `LauncherContentView.swift`).
- [ ] Use one commit for each ticket or logical change. Stage only the files you changed.
- [ ] The commit uses a conventional prefix (`feat:`, `fix:`, `refactor:`, `test:`, `docs:`, `chore:`) and explains the scope and intent.
- [ ] The commit has no `Co-Authored-By` or other attribution line.
- [ ] The next step, if one exists, is small and concrete.

## Non-Negotiable Invariants (must never be violated)

Section 3 of `docs/ROL-6-spec-and-invariants.md` is the only place with the full wording and known limitations.
Do not copy the full wording into other files. Refer to an invariant by its ID.
To change an invariant, the user must approve the change, and the spec must change in the same commit.

- I-1. The source card is never changed.
- I-2. The library is never overwritten.
- I-3. Every file goes through staging, in a fixed order.
- I-4. Embedded metadata is preserved (only exception: Film Mode).
- I-5. Verification cannot be turned off or skipped.
- I-6. The receipt is always written.
- I-7. A failed run keeps its evidence.
- I-8. Filesystem dates are preserved.
- I-9. Writes go only to allowed places.
- I-10. The path strategy is fixed at run start.

## Writing Style (ASD-STE100)

Write all docs and all chat replies in ASD-STE100 Simplified Technical English:
- Use short sentences. Steps: 20 words or fewer. Descriptions: 25 words or fewer.
- Write one idea in each sentence.
- Use the active voice. Use imperative verbs for steps.
- Use one word for one meaning. Do not swap synonyms for the same thing.
- Do not use idioms.

Old docs are not in this style yet. Do not rewrite them without a request. Use the style for new and edited text.

## Decision Log

Record each decision that changes behavior or direction. Put the record in an ADR in `docs/adr/` or in the spec.
Each record has:
- Date
- Context: what changed or was unclear
- Decision: the option chosen
- Why: the trade-off
- Revisit trigger: the condition that would reopen the decision

## Commands (run from the repo root)

| Command | Purpose |
| --- | --- |
| `swift build` | Debug build of the CLI and the launcher. |
| `swift test` | Unit tests. |
| `python3 scripts/build-e2e-fixtures.py` | Build the source-card fixtures. Add `--check` to only check them. |
| `scripts/run-e2e-tests.sh` | Build debug binaries once and run all e2e scripts in turn. This is the mandatory baseline verification. |
| `scripts/run-dev-app.sh` | Build a debug `Fyluro-dev.app` in `dist/` and open it. |
| `scripts/package-macos-app.sh --version <v>` | Build the release app bundle. |
| `scripts/release-app-smoke-test.sh --version <v>` | Smoke test of the packaged app. Add `--with-launcher-check` for the manual launcher check. |
| `scripts/release-prepare.sh --bump <level>` | Validate, package and update release metadata (`release-app-smoke-test.sh` runs automatically). |
| `scripts/release-publish.sh` | Publish a prepared release with git and GitHub CLI. |
| `scripts/release-cut.sh --bump <level>` | Prepare and publish in one command. |

Each script accepts `-h` and prints its usage.
