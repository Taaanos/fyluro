# Stories and Future Work

This file is the single place for planned features and future work in RollKeep.
The product source of truth is [ROL-6-spec-and-invariants.md](../ROL-6-spec-and-invariants.md).
Small features stay directly in this file.
Large stories link to a dedicated file in `docs/work/stories/` or `docs/ui-overhaul/`.

Status values: `open`, `in-progress`, `blocked`, `deferred`, `parked`, `done`.

## Summary

| ID | Story | Status | Needs decision | Where |
| --- | --- | --- | --- | --- |
| UI-S6 | UI Overhaul: Accessibility and finish | `open` | Yes (3 decisions in file) | [story-6-accessibility-finish.md](../ui-overhaul/story-6-accessibility-finish.md) |
| UI-S3 | UI Overhaul: 3 deferred visual checks | `deferred` | No | [story-3-import-states.md](../ui-overhaul/story-3-import-states.md#result-and-open-checks-2026-10-05) |
| ST-1 | Film Mode metadata strategy (RAW and XMP/EXIF options) | `blocked` | Yes (Q1 to Q8 in file) | [film-mode-metadata-strategy.md](stories/film-mode-metadata-strategy.md) |
| ST-8 | Hardware-verified storage writes (fsync and cache bypass) | `open` | Yes (Q1 to Q4 in file) | [hardware-verification-cache-bypass.md](stories/hardware-verification-cache-bypass.md) |
| ST-9 | Prevent idle sleep during ingest | `done` | No | [Below](#completed-stories) |
| ST-10 | Live mount detection and Disk Image (.dmg) filtering | `done` | No | [Below](#completed-stories) |
| ST-11 | Graceful CLI signal handling (SIGINT, SIGTERM, SIGHUP) | `open` | No | [Below](#st-11-graceful-cli-signal-handling-sigint-sigterm-sighup) |
| ST-12 | Sanitize control and bidi characters in human CLI output (RT-P2-04) | `open` | No | [Below](#st-12-sanitize-control-and-bidi-characters-in-human-cli-output-rt-p2-04) |
| ST-2 | Eject card after a verified import | `parked` | Yes (UX and error rules) | [Below](#st-2-eject-card-after-a-verified-import) |
| ST-3 | Setup-mistake prevention (preflight, checklist, layout summary) | `parked` | Yes (scope and layout) | [Below](#st-3-setup-mistake-prevention) |
| ST-4 | Rebrand, app icon, and visual identity | `parked` | Yes (new app name) | [Below](#st-4-rebrand-app-icon-and-visual-identity) |
| ST-5 | Performance audit follow-ups (scan, commit, UI, PDF) | `parked` | No | [Below](#st-5-performance-audit-follow-ups) |
| ST-6 | Red-team and E2E test coverage gaps | `parked` | No | [Below](#st-6-red-team-and-e2e-test-coverage-gaps) |
| ST-7 | Check why `.xmp` sidecars import as `-1.xmp` on a second run | `parked` | No | [Below](#st-7-check-why-xmp-sidecars-import-as--1xmp-on-a-second-run) |
| UI-S0..S5 | UI Overhaul: Foundations, main window, Film Mode, states, PDF, Settings | `done` | No | [ui-overhaul/README.md](../ui-overhaul/README.md) |

---

## Active and blocked stories

### UI-S6. UI Overhaul: Accessibility and finish

- **Status:** `open` (not started)
- **Depends on:** UI-S0 through UI-S5 merged
- **Spec / Invariants:** ROL-6 Sections 2 and 10 (presentation only)
- **Detail file:** [story-6-accessibility-finish.md](../ui-overhaul/story-6-accessibility-finish.md)

**Goal:**
Add VoiceOver labels, Full Keyboard Access checks, contrast checks, and Reduce Motion / Increase Contrast verification across the app.

**Next step:**
Confirm the three questions in "Decisions to confirm before you write code" inside [story-6-accessibility-finish.md](../ui-overhaul/story-6-accessibility-finish.md).

---

### UI-S3. UI Overhaul: 3 deferred visual checks

- **Status:** `deferred` (code is done and committed)
- **Detail file:** [story-3-import-states.md](../ui-overhaul/story-3-import-states.md#result-and-open-checks-2026-10-05)

**Goal:**
Capture and review three missing screenshots in the dev app:
1. A stopped import (neutral pause mark).
2. Reduce Motion turned on (static route arrow while importing).
3. Light appearance on the importing screen.

**Next step:**
Run `scripts/run-dev-app.sh`, capture the three states, and save them in `docs/ui-overhaul/after/`.

---

### ST-1. Film Mode metadata strategy

- **Status:** `blocked` (needs owner answers Q1 to Q8)
- **Type:** Behavior change (needs an ADR and a spec change before code)
- **Spec / Invariants:** I-1, I-4, I-5, I-8, I-9, ROL-6 Sections 3 and 5
- **Detail file:** [film-mode-metadata-strategy.md](stories/film-mode-metadata-strategy.md)

**Goal:**
Decide how Film Mode records shot camera and film data without breaking verification guarantees or leaving RAW files out.

**Next step:**
Answer questions Q1 to Q8 in [film-mode-metadata-strategy.md](stories/film-mode-metadata-strategy.md).

---

### ST-8. Hardware-verified storage writes (fsync and cache bypass)

- **Status:** `open` (needs owner answers Q1 to Q4)
- **Type:** Behavior and performance evaluation (needs an ADR and spec review)
- **Spec / Invariants:** I-3, I-5, ROL-6 Sections 3 and 5.4, ADR 0001
- **Detail file:** [hardware-verification-cache-bypass.md](stories/hardware-verification-cache-bypass.md)

**Goal:**
Evaluate adding unbuffered physical verification (`fcntl(fd, F_NOCACHE, 1)`) and disk write flush (`fcntl(fd, F_FULLFSYNC)`), or adding a user toggle in Settings with speed and durability trade-off notices.

**Next step:**
Answer questions Q1 to Q4 in [hardware-verification-cache-bypass.md](stories/hardware-verification-cache-bypass.md).

---

### ST-11. Graceful CLI signal handling (SIGINT, SIGTERM, SIGHUP)

- **Status:** `open`
- **Spec / Invariants:** I-6, I-7, ROL-6 Section 7, Section 8
- **Code:** `Sources/rollkeep/main.swift`, `Sources/RollKeepEngine/IngestSession.swift`

**Goal:**
Capture termination signals (`SIGINT`, `SIGTERM`, `SIGHUP`) during CLI runs.
Trigger cooperative cancellation on the active `IngestSession`.
Let the engine stop at the next chunk boundary.
Ensure RollKeep retains evidence and writes the final aborted receipt (`I-6`, `I-7`).
A second signal forces immediate exit.

**Next step:**
1. Use `DispatchSource.makeSignalSource` in the CLI target for `SIGINT`, `SIGTERM`, and `SIGHUP`.
2. Connect the signal handler to `session.cancel()`.
3. Add a test in `scripts/` to confirm signal cancellation produces a complete aborted receipt.

---

### ST-12. Sanitize control and bidi characters in human CLI output (RT-P2-04)

- **Status:** `open`
- **Spec / Invariants:** ROL-6 Section 8, Section 9
- **Related red-team finding:** [red-team-ingest-test-matrix.md](../red-team-ingest-test-matrix.md#rt-p2-04-hostile-source-filenames-must-be-handled-safely-and-legibly) (`RT-P2-04`)
- **Code:** `Sources/rollkeep/`, `Sources/RollKeepCore/`

**Goal:**
Sanitize filenames shown in human-readable CLI output.
Strip or escape ANSI control sequences, C0/DEL control bytes, and Unicode bidirectional override characters (such as U+202E).
Prevent terminal display corruption and extension spoofing in terminal logs.
Preserve exact filenames on disk and in machine-readable NDJSON receipts.

**Next step:**
1. Implement a safe text formatting helper for terminal display strings.
2. Apply the helper across human-readable CLI logging and summary renderers.
3. Verify against `scripts/e2e-hostile-filenames-test.sh`.

---

## Parked future work

### ST-2. Eject card after a verified import

- **Status:** `parked`
- **Source:** Moved from `docs/ui-overhaul/README.md` (2026-10-03 plan)
- **Spec / Invariants:** I-1, ROL-6 Section 2

**Goal:**
Let the user eject the source card after a verified import from the Complete screen.
This fits `I-1` because ejecting unmounts the card only after ingest ends.

**Next step:**
Design the UI trigger, define behavior when unmount fails or another app uses the volume, and check ROL-6 before starting.

---

### ST-3. Setup-mistake prevention

- **Status:** `parked`
- **Source:** Moved from `docs/ui-overhaul/README.md` (2026-10-03 plan; old plan deleted, exists in git history)
- **Spec / Invariants:** ROL-6 Sections 2, 4, and 10

**Goal:**
Prevent setup mistakes with a preflight confirmation sheet, a readiness checklist, or a clear layout summary on the main screen.

**Next step:**
Decide whether this is still needed after the UI overhaul, then scope a small story.

---

### ST-4. Rebrand, app icon, and visual identity

- **Status:** `parked`
- **Code:** `AppBrand.name` in `Sources/RollKeepCore` / `Sources/rollkeepLauncher`
- **Source:** Moved from `docs/ui-overhaul/README.md` (`docs/ui-overhaul/findings.md`, item G)

**Goal:**
Replace "RollKeep" with the chosen final brand name, new app icon, and visual identity.
The UI overhaul centralized user-visible name strings under `AppBrand.name` to make this easy.

**Next step:**
Choose the final product name and icon, then update `AppBrand.name`, bundle metadata, and docs.

---

### ST-5. Performance audit follow-ups

- **Status:** `parked`
- **Detail files:**
  - [performance-audit-findings-2026-07-16.md](../performance-audit-findings-2026-07-16.md)
  - [performance-audit-findings-2026-07-16-part2.md](../performance-audit-findings-2026-07-16-part2.md)

**Goal:**
Implement the remaining performance improvements that do not weaken verification or durability (`I-5`, `I-6`, ADR 0001):
- Round 1 remaining: Finding 3 (sidecar sibling cache threading), Finding 4 (regex re-scan in `EmbeddedVideoMetadataTextParser`).
- Round 2 remaining: Findings B to H (hoist normalizer regexes, CLI logger formatter, `isOpaqueModelCode` strip, `createDirectory` dedup, triple `CameraLabeler.infer`, Launcher receipt-preview coalescing, PDF font memoization).

**Next step:**
Pick the next item from "Suggested action sequence" in [performance-audit-findings-2026-07-16-part2.md](../performance-audit-findings-2026-07-16-part2.md#L369-L382) when speed work is needed.

---

### ST-6. Red-team and E2E test coverage gaps

- **Status:** `parked`
- **Detail files:**
  - [Tests/e2e-ingest-matrix.md](../../Tests/e2e-ingest-matrix.md#known-coverage-gaps-spec-requirements-with-no-matrix-row)
  - [red-team-ingest-test-matrix.md](../red-team-ingest-test-matrix.md)

**Goal:**
Close the remaining test gaps listed in the test matrices:
- Automate `E2E-037` (duplicate detection scope across the library) and `E2E-038` (concurrent runs against one destination).
- Cover the 10 unmapped spec requirements listed under "Known Coverage Gaps" in `Tests/e2e-ingest-matrix.md`.

**Next step:**
Pick one high-impact scenario from "Known Coverage Gaps" and add a unit or E2E test.

---

### ST-7. Check why `.xmp` sidecars import as `-1.xmp` on a second run

- **Status:** `parked`
- **Source:** Moved from `docs/ui-overhaul/README.md`

**Goal:**
Confirm why `.xmp` sidecars received a `-1.xmp` conflict rename on a second import of the test card.
Inspect the S4 PDF receipt or `.ndjson` receipt for a two-run test to confirm whether the source `.xmp` bytes changed or another cause triggered the conflict.

**Next step:**
Run two imports of a card with `.xmp` sidecars, inspect the S4 PDF receipt, and either close this item or open a `KI-N` bug in [bugs.md](bugs.md).

---

## Completed stories

- **UI-S0 to UI-S5:** Foundations, main window, Film Mode sheet, import states, PDF receipt, and Settings. See [ui-overhaul/README.md](../ui-overhaul/README.md).
- **ST-9 (2026-11-15):** Prevent idle sleep during ingest. `IngestSession.run()` now acquires `kIOPMAssertionTypePreventUserIdleSystemSleep` via `IdleSleepAssertion.swift` and releases it in a `defer` block. Fixes [KI-9](bugs.md#ki-9-the-engine-does-not-prevent-idle-sleep-during-an-import).
- **ST-10 (2026-11-15):** Live mount detection and Disk Image (`.dmg`) filtering. `LauncherViewModel` now watches `NSWorkspace` mount and unmount notifications while idle on setup, and `LauncherVolumeInspector` excludes disk images via Disk Arbitration. Fixes [KI-7](bugs.md#ki-7-the-app-does-not-detect-a-card-that-the-user-inserts-after-it-opens).
