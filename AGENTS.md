# AGENTS.md

## Mandatory Spec-First Workflow

Before implementing, modifying, or reviewing any feature, always read:
- `docs/ROL-6-spec-and-invariants.md`

Treat that document as the product source of truth for production behavior and invariants.
Architecture direction: RollKeep is app-first, with the CLI as an engine/complementary interface. Some capabilities may be app-only by design.

Required behavior for every feature task:
- Confirm spec alignment before writing code.
- If requirements are ambiguous, resolve using the spec first.
- If code/task instructions conflict with the spec, stop and ask the user before proceeding.
- In implementation summaries, include a short "Spec check" note listing the spec sections used.

## Work Loop
1. Read `docs/ROL-6-spec-and-invariants.md` and `docs/working-style.md`. Check `docs/work/README.md` for open bugs and active stories.
2. Name the spec sections that apply. If the task conflicts with the spec or an invariant, stop and ask the user.
3. Settle open questions with the user before you write code.
4. Build the smallest safe change. Add or update tests.
5. Run `swift test` and `scripts/run-e2e-tests.sh`.
6. Check the Definition of done in `docs/working-style.md`.
7. Summarize with a "Spec check" note. Commit when the work passes the gates. Use one commit for each ticket or logical change. Stage only the files you changed. The user can ask you to amend or reset.

## Non-Negotiable Invariants (must never be violated)
Full wording, with known limitations: Section 3 of `docs/ROL-6-spec-and-invariants.md`. Refer to an invariant by its ID.
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

## Commands (run from the repo root)
| Command | Purpose |
| --- | --- |
| `swift build` | Debug build of the CLI and the launcher. |
| `swift test` | Unit tests. |
| `python3 scripts/build-e2e-fixtures.py` | Build the source-card fixtures. Add `--check` to only check them. |
| `scripts/run-e2e-tests.sh` | Run all e2e scripts in turn. This is the safety floor. |
| `scripts/run-dev-app.sh` | Build a debug `RollKeep-dev.app` in `dist/` and open it. |
| `scripts/package-macos-app.sh` | Build the release app bundle. |
| `scripts/release-app-smoke-test.sh` | Smoke test of the packaged app. Add `--with-launcher-check` for the manual launcher check. |
| `scripts/release-prepare.sh` | Validate, package and update release metadata. |
| `scripts/release-publish.sh` | Publish a prepared release with git and GitHub CLI. |
| `scripts/release-cut.sh` | Prepare and publish in one command. |

Each script accepts `-h` and prints its usage.

## User Workflow Preferences (Persistent)
- Write all docs and all chat replies in ASD-STE100 Simplified Technical English (see `docs/working-style.md`).
- When committing, use conventional commit prefixes (for example: `feat:`, `fix:`, `refactor:`, `test:`, `docs:`, `chore:`).
- Write commit messages with enough context to explain the scope and intent of the change (not terse one-liners without ticket/feature detail).
- Do not add `Co-Authored-By` or other attribution lines to commits or pull requests.

## Release Pipeline Notes (Persistent)
- `scripts/release-prepare.sh` runs `scripts/release-app-smoke-test.sh` automatically after packaging, verifying the actual assembled `dist/RollKeep.app` (relocated outside the repo) via its packaged CLI binary. This is a mandatory gate.
- `scripts/release-app-smoke-test.sh --with-launcher-check` (fake-SD-card + real `rollkeep-launcher` process launch) is a **manual, opt-in step** — it is NOT run automatically by `release-prepare.sh` because it depends on window-server/session behavior on the machine running it. Run it by hand before shipping any release that touches launcher startup, auto-source-detection, or scan-on-launch code (`Sources/rollkeepLauncher/LauncherViewModelActions.swift`, `LauncherVolumeDefaults.swift`, `LauncherContentView.swift`'s `.task` block).
