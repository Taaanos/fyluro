# Stories and Future Work

This file is the single place for planned features and future work in Fyluro.
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
| ST-8 | Hardware-verified storage writes (fsync and cache bypass) | `done` | No | [hardware-verification-cache-bypass.md](stories/hardware-verification-cache-bypass.md) |
| ST-18 | User-facing UI toggle for hardware verification depth | `parked` | Yes (UX and Settings placement) | [Below](#st-18-user-facing-ui-toggle-for-hardware-verification-depth) |
| ST-19 | Incremental speed and integrity options (preliminary research) | `parked` | Yes (Q1 to Q3 in file) | [incremental-speed-and-integrity-options.md](stories/incremental-speed-and-integrity-options.md) |
| ST-20 | Custom path engine and preset templates | `parked` | Yes (refinement Q1 to Q8) | [custom-path-engine.md](stories/custom-path-engine.md) |
| ST-13 | Single copy stream for rotational HDD destinations | `done` | No | [Below](#completed-stories) |
| ST-14 | Receipt write batching for post-phase bursts | `open` | Yes (benchmark after ADR 0003) | [Below](#st-14-receipt-write-batching-for-post-phase-bursts) |
| ST-15 | GitHub Actions public release pipeline | `done` | No | [Below](#completed-stories) |
| ST-17 | GitHub Actions CI and E2E test pipeline | `parked` | No (solo dev; revisit for PRs) | [Below](#st-17-github-actions-ci-and-e2e-test-pipeline) |
| ST-16 | Clean-clone synthetic E2E fixtures for public contributors and CI | `done` | No | [Below](#completed-stories) |
| ST-9 | Prevent idle sleep during ingest | `done` | No | [Below](#completed-stories) |
| ST-10 | Live mount detection and Disk Image (.dmg) filtering | `done` | No | [Below](#completed-stories) |
| ST-11 | Graceful CLI signal handling (SIGINT, SIGTERM, SIGHUP) | `done` | No | [Below](#completed-stories) |
| ST-12 | Sanitize control and bidi characters in human CLI output (RT-P2-04) | `done` | No | [Below](#completed-stories) |
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

### ST-14. Receipt write batching for post-phase bursts

- **Status:** `open` (not started)
- **Type:** Performance evaluation (check `I-6` and Section 10)
- **Spec / Invariants:** I-6, ROL-6 Section 10, ADR 0003
- **Code:** `Sources/FyluroEngine/ReceiptWriter.swift`, `Sources/FyluroEngine/IngestReceiptEvents.swift`, `Sources/FyluroEngine/IngestPipelinePhases.swift`

**Goal:**
Evaluate the remaining cost of the post-phase loops (`FILE_COPIED`, `FILE_VERIFY_STARTED`, `FILE_VERIFIED`, `FILE_COMMIT_STARTED`, `FILE_COMMITTED`) now that `ADR 0003` removed per-line `fsync` calls. On 5,000 files, those loops still run roughly 25,000 `write()` calls, JSON encodes, and `onLineAppended` callbacks.

**Questions to evaluate:**
1. Measure CPU and wall time of the 5,000-file loops with `ADR 0003` active.
2. Decide if buffering burst `write()` calls into one buffer improves speed enough to justify the complexity.
3. Define how `injectedDestinationAppendFailureAtEventIndex` and `onLineAppended` behave across a multi-event write buffer (and check overlap with `ST-5` Finding G).
4. Check if `FILE_VERIFY_STARTED` and `FILE_VERIFIED` still add value when written back-to-back after verification ends.

**Next step:**
Benchmark a 5,000-file ingest after `ADR 0003` and decide whether burst `write()` batching is needed.

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
- **Source:** Moved from `docs/ui-overhaul/README.md` (2026-10-03 plan)
- **Spec / Invariants:** ROL-6 Sections 2, 4, and 10

**Goal:**
Prevent setup mistakes with a preflight confirmation sheet, a readiness checklist, or a clear layout summary on the main screen.

**Next step:**
Decide whether this is still needed after the UI overhaul, then scope a small story.

---

### ST-4. Rebrand, app icon, and visual identity

- **Status:** `parked`
- **Code:** `AppBrand.name` in `Sources/FyluroCore` / `Sources/fyluroLauncher`
- **Source:** Moved from `docs/ui-overhaul/README.md` (`docs/ui-overhaul/findings.md`, item G)

**Goal:**
Replace "Fyluro" with the chosen final brand name, new app icon, and visual identity.
The UI overhaul centralized user-visible name strings under `AppBrand.name` to make this easy.

**Next step:**
Choose the final product name and icon, then update `AppBrand.name`, bundle metadata, and docs.

---

### ST-5. Performance audit follow-ups

- **Status:** `parked`
- **Detail files:**
  - [performance-audit-2026-07-16.md](../audits/performance-audit-2026-07-16.md)
  - [performance-audit-2026-07-16-part2.md](../audits/performance-audit-2026-07-16-part2.md)

**Goal:**
Implement the remaining performance improvements that do not weaken verification or durability (`I-5`, `I-6`, ADR 0001):
- Round 1 remaining: Finding 3 (sidecar sibling cache threading), Finding 4 (regex re-scan in `EmbeddedVideoMetadataTextParser`).
- Round 2 remaining: Findings B to H (hoist normalizer regexes, CLI logger formatter, `isOpaqueModelCode` strip, `createDirectory` dedup, triple `CameraLabeler.infer`, Launcher receipt-preview coalescing, PDF font memoization).

**Next step:**
Pick the next item from "Suggested action sequence" in [performance-audit-2026-07-16-part2.md](../audits/performance-audit-2026-07-16-part2.md#L369-L382) when speed work is needed.

---

### ST-6. Red-team and E2E test coverage gaps

- **Status:** `parked`
- **Detail files:**
  - [Tests/e2e-ingest-matrix.md](../../Tests/e2e-ingest-matrix.md#known-coverage-gaps-spec-requirements-with-no-matrix-row)
  - [red-team-ingest-test-matrix.md](../testing/red-team-ingest-test-matrix.md)

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

### ST-17. GitHub Actions CI and E2E test pipeline

- **Status:** `parked` (split from `ST-15` on 2026-11-20)
- **Type:** Tooling and CI workflow
- **Related:** [github-actions-ci.md](stories/github-actions-ci.md), [run-e2e-tests.sh](../../scripts/run-e2e-tests.sh)

**Goal:**
Run `swift test`, `build-e2e-fixtures.py --check`, and a quota-safe [run-e2e-tests.sh](../../scripts/run-e2e-tests.sh) workflow on pull requests and pushes to `main`.

**Why parked:**
The owner currently works solo without pull requests and runs tests locally. Revisit this story when contributors join or pull-request checks are needed.

**Next step:**
Measure `swift test` and `*e2e*-test.sh` runtimes on a GitHub `macos-15` runner, confirm headless compatibility, and add `.github/workflows/ci.yml`.

---

### ST-18. User-facing UI toggle for hardware verification depth

- **Status:** `parked` (split from `ST-8` on 2026-11-20)
- **Type:** Behavior and UI setting (needs spec and ADR review before code)
- **Spec / Invariants:** I-5, I-10, ROL-6 Sections 3 and 8, ADR 0001, ADR 0005
- **Related:** [hardware-verification-cache-bypass.md](stories/hardware-verification-cache-bypass.md), [0005-hardware-verification-cache-bypass.md](../adr/0005-hardware-verification-cache-bypass.md)

**Goal:**
Expose the engine's `hardwareVerification` flag (`F_FULLFSYNC` and `F_NOCACHE`, currently on by default) as a user-facing toggle in Settings (for example in the `Transfers` tab) with clear speed and durability trade-off notices for slow external mechanical hard drives.

**Why parked:**
`ST-8` enabled direct hardware verification by default and gated it behind `IngestRequest.hardwareVerification` and `StagingCopyEngine.Configuration.hardwareVerification`. We will add the UI setting later if users with slow external drives need it.

**Next step:**
Decide the Settings tab placement, warning copy, and whether the setting is app-only or also exposed on the CLI, then update `ROL-6` and `ADR 0005`.

---

### ST-19. Incremental speed and integrity options (preliminary research)

- **Status:** `parked` (preliminary research added 2026-11-20)
- **Type:** Preliminary research and design evaluation (needs owner answers Q1 to Q3, an ADR, and spec review)
- **Spec / Invariants:** I-2, I-3, I-5, I-7, ROL-6 Sections 1, 3, 7, 8, and 11, ADR 0001, ADR 0005
- **Detail file:** [incremental-speed-and-integrity-options.md](stories/incremental-speed-and-integrity-options.md)

**Goal:**
Evaluate incremental speed options that keep HDD and SSD wear equal or lower: live-hash pre-copy duplicate checks against the final library (Option 0, zero integrity loss), OS-cached verification (Option 1, `ST-18`), sampled physical read-back on large files (Option 2), metadata duplicate skips (Option 3), and size-only verification (Option 4).

**Next step:**
Review the preliminary research in [incremental-speed-and-integrity-options.md](stories/incremental-speed-and-integrity-options.md) when speed work is prioritized, and decide whether to split Option 0 into its own ticket.

---

### ST-20. Custom path engine and preset templates

- **Status:** `parked` (added 2026-11-22; needs refinement)
- **Type:** Behavior and UI feature (needs spec review and updates before code)
- **Spec / Invariants:** I-2, I-6, I-9, I-10, ROL-6 Sections 2, 4, 6, 7, and 10
- **Detail file:** [custom-path-engine.md](stories/custom-path-engine.md)

**Goal:**
Let users assemble destination path schemas from tokens (`YYYY`, `MM`, `DD`, `YYYYMM`, `camera-model`, `camera-serial-number`, `media-type`, `raw-split`, and a per-run `event-tag`).
Include folder-tree visualization, JSON preset persistence (`PathTemplates.json`), built-in v1 preset migration, and notes on a future on-device macOS decision model.

**Next step:**
Refine open questions 1 to 8 in [custom-path-engine.md](stories/custom-path-engine.md) before drafting spec changes or implementation tickets.

---

## Completed stories

- **UI-S0 to UI-S5:** Foundations, main window, Film Mode sheet, import states, PDF receipt, and Settings. See [ui-overhaul/README.md](../ui-overhaul/README.md).
- **ST-9 (2026-11-15):** Prevent idle sleep during ingest. `IngestSession.run()` now acquires `kIOPMAssertionTypePreventUserIdleSystemSleep` via `IdleSleepAssertion.swift` and releases it in a `defer` block. Fixes [KI-9](bugs.md#ki-9-the-engine-does-not-prevent-idle-sleep-during-an-import).
- **ST-10 (2026-11-15):** Live mount detection and Disk Image (`.dmg`) filtering. `LauncherViewModel` now watches `NSWorkspace` mount and unmount notifications while idle on setup, and `LauncherVolumeInspector` excludes disk images via Disk Arbitration. Fixes [KI-7](bugs.md#ki-7-the-app-does-not-detect-a-card-that-the-user-inserts-after-it-opens).
- **ST-11 (2026-11-15):** Graceful CLI signal handling (`SIGINT`, `SIGTERM`, `SIGHUP`). `CLISignalMonitor` and `CLISignalCoordinator` capture termination signals during CLI ingest, cancel `IngestSession` on the first signal so evidence and aborted receipts are kept (`I-6`, `I-7`), and exit immediately on a second signal. Covered by `CLISignalHandlerTests` and `scripts/e2e-cli-signal-cancellation-test.sh`.
- **ST-12 (2026-11-15):** Sanitize control and bidi characters in terminal CLI output (`RT-P2-04`). `TerminalTextSanitizer` escapes C0, DEL, C1, line-separator, and bidi control characters as `\u{XXXX}` in `StructuredLogger`, human `FinalSummaryRenderer` output, `VolumeResolver`, and camera catalog warnings. Exact filenames stay unchanged on disk, in NDJSON receipts (`I-6`), and in `--json` summaries. Covered by `TerminalTextSanitizerTests`, `FinalSummaryRendererTests`, and `scripts/e2e-hostile-filenames-test.sh`.
- **ST-13 (2026-11-16):** Safe single copy stream default and IOKit destination medium detection. `IOKitDestinationMediumDetector` detects `rotational_hdd`, `solid_state`, or `unknown` at session start and logs `destination_medium_type` in `SESSION_STARTED` and `command_started`. App, CLI, and engine default `max_parallel_copies` to `1`; explicit CLI `--max-parallel-copies` flags remain honored. Settings adds a `Transfers` tab showing the detected medium, locking HDDs to `1`, and allowing `1` or `2` on non-HDD destinations. Covered by `DestinationMediumDetectorTests`, `LauncherTransferSettingsTests`, and `FyluroCLIParallelCopiesTests`.
- **ST-16 (2026-11-16):** Clean-clone synthetic E2E fixtures. Added deterministic pure-Python builders in `scripts/build-e2e-fixtures.py` (`--synthetic`, default) for `SD_CARD1` and `SD_CARD2` (43 files, ~14 KB), updated `Tests/TestingDirs/fixture-manifest.json`, and updated E2E and smoke test scripts to generate synthetic fixtures automatically when absent. See [synthetic-e2e-fixtures.md](stories/synthetic-e2e-fixtures.md).
- **ST-15 (2026-11-20):** GitHub Actions public release pipeline. Added `.github/workflows/release.yml` on `macos-26` (Xcode 26) to run `swift test`, `scripts/run-e2e-tests.sh`, `scripts/package-macos-app.sh`, `scripts/release-app-smoke-test.sh`, `actions/attest-build-provenance`, and GitHub Release creation on `v*.*.*` tags or `workflow_dispatch`. Updated `README.md` with `.sha256`, `gh attestation verify`, and Gatekeeper instructions. Verified on `macos-26` via `workflow_dispatch` (run `44694313657`). See [github-actions-ci.md](stories/github-actions-ci.md).
- **ST-8 (2026-11-20):** Hardware-verified storage writes (Option C: two-pass batch copy and unbuffered verify). `StagingCopyEngine` now runs Pass 1 (copy all files to staging via POSIX file descriptors with `F_NOCACHE` on staging writes, storing `sourceHash` in memory), issues one `fcntl(fd, F_FULLFSYNC)` barrier on the destination volume (with `fsync` fallback) after Pass 1 finishes, and runs Pass 2 (verify all staged files with `F_NOCACHE`, per-chunk cancellation checks, and live `.phaseChanged(.verify)` / `.fileVerifyProgress` / `.fileVerified` events). Launcher UI now splits Copy (`18% -> 52%`) and Verify (`52% -> 86%`) progress bands with live verified-item text. Gated behind `hardwareVerification: Bool = true` on `IngestRequest` and `StagingCopyEngine.Configuration`, and recorded as `hardware_verification` in `SESSION_STARTED` and `command_started`. Future UI toggle parked as `ST-18`. See [hardware-verification-cache-bypass.md](stories/hardware-verification-cache-bypass.md) and [0005-hardware-verification-cache-bypass.md](../adr/0005-hardware-verification-cache-bypass.md).
