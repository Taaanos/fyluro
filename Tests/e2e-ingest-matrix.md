# E2E Ingest Matrix (Tests)

Status: active test matrix for fixture-backed end-to-end safety checks  
Last updated: 2026-07-16  
Spec source of truth: `docs/ROL-6-spec-and-invariants.md`

## Scope
This matrix tracks real fixture and runtime E2E coverage for ingest behavior, with emphasis on the ROL-6 non-negotiable invariants:

- no delete on card
- no overwrite in library
- staging-first flow
- receipt always written (with failover)
- destination-constrained writes

## How To Run Current Baseline

1. `swift test --filter IngestPreparationServiceTests`
2. `scripts/release-smoke-test.sh`
3. `scripts/existing-hdd-e2e-test.sh`
4. `scripts/e2e-fault-injection-test.sh`
5. `scripts/e2e-verify-failure-test.sh`
6. `scripts/e2e-timestamp-and-write-audit-test.sh`
7. `scripts/e2e-crash-restart-recovery-test.sh`
8. `scripts/e2e-dry-run-truthfulness-test.sh`
9. `scripts/e2e-overlap-preflight-test.sh`
10. `scripts/e2e-symlink-skip-test.sh`
11. `scripts/e2e-unreadable-source-test.sh`
12. `scripts/e2e-unicode-normalization-test.sh`
13. `scripts/app-e2e-launcher-test.sh`
14. `scripts/package-macos-app.sh --version $(cat VERSION)`
15. `scripts/e2e-boxwalker-overflow-crash-test.sh`
16. `scripts/e2e-metadata-length-bomb-test.sh`
17. `scripts/e2e-hostile-filenames-test.sh`

Note (corrected 2026-07-13, updated 2026-07-14): `scripts/run-e2e-tests.sh` does not orchestrate all 14 steps above. It globs `scripts/*e2e*-test.sh`, which covers steps 3–12 (and includes `app-e2e-launcher-test.sh`) but not step 1's `swift test` filter, step 2's `release-smoke-test.sh`, or step 14's `package-macos-app.sh` — none of those three match the glob. Run those three explicitly; don't assume the orchestrator covers the full baseline. `scripts/e2e-unicode-normalization-test.sh` requires `hdiutil` (creates and mounts real HFS+/exFAT/APFS disk images) — it will not run in an environment without Disk Arbitration access.

Default speed profile knobs:

- `scripts/existing-hdd-e2e-test.sh`
  - `ROLLKEEP_E2E_FIXTURE_PROFILE=fast` (default)
  - `ROLLKEEP_E2E_WORKERS=4` (default)
- `scripts/app-e2e-launcher-test.sh`
  - `ROLLKEEP_APP_E2E_WORKERS=4` (default)

Full-fixture fallback for existing-HDD E2E:

```bash
ROLLKEEP_E2E_FIXTURE_PROFILE=full ROLLKEEP_E2E_WORKERS=1 scripts/existing-hdd-e2e-test.sh
```

## Fixture Inventory Used For E2E

The source cards are gitignored real-media fixtures rebuilt reproducibly by
`scripts/build-e2e-fixtures.py` from a local directory of real camera files
(default `Tests/TestingDirs`, override with
`ROLLKEEP_FIXTURE_SOURCE_DIR`). The script's in-file mapping table is the
source of truth for card contents; it writes
`Tests/TestingDirs/fixture-manifest.json` (committed) and supports `--check`
for drift detection, which `scripts/run-e2e-tests.sh` runs as a preflight.

- `Tests/TestingDirs/SD_CARD1` — Apple phone card: 10 files / ~318 MB
  (6 photos, 4 videos; iPhone 12 mini/13 Pro/15 Pro/16 HEIC/DNG/MOV, one
  PNG screenshot without camera EXIF for `unknown-camera` coverage, one
  Blackmagic-app clip with nonstandard naming)
- `Tests/TestingDirs/SD_CARD2` — mixed multi-camera card: 32 files / ~1.5 GB
  (17 photos, 10 videos, 2 transferable sidecars, 3 scanner-skipped
  companions). Sony rx100/rx100m6/a7c2/a6000/a380, Canon 5DM2, GoPro
  Hero10, DJI action-4/action-6/mini-4-pro/pocket-3, Insta360 `.insv`,
  Samsung, one Lightroom export. Includes same-basename RAW+JPG pairs
  (`DSC00421`, `DJI_20240126194607_0117_D`), a real Sony
  `PRIVATE/M4ROOT/CLIP` clip+`M01.XML` sidecar pair, a DJI `.SRT` sidecar
  pair, and intentionally unsupported companions (`.GPR`, `.WAV`) that the
  scanner must skip without errors
- existing-HDD/app path-matrix fast profile uses slim runtime subsets
  (pinned paths — keep in sync with `scripts/build-e2e-fixtures.py`,
  `scripts/existing-hdd-e2e.py`, the `E2E_EXISTING_HDD_*/fixture.json`
  files, `LauncherAppE2ETests.swift`, and `scripts/e2e-verify-failure-test.sh`):
  - `SD_CARD1`: `DCIM/IMG_8236.HEIC`, `DCIM/IMG_0187.HEIC`
  - `SD_CARD2`: `DCIM/100MSDCF/DSC01930.JPG`, `PRIVATE/M4ROOT/CLIP/20250824_C2864.MP4`
- `Tests/TestingDirs/E2E_EXISTING_HDD_BASELINE_SD1`
- `Tests/TestingDirs/E2E_EXISTING_HDD_BASELINE_SD2`
- `Tests/TestingDirs/E2E_EXISTING_HDD_DUPLICATE_PRESEEDED_SD1`
- `Tests/TestingDirs/E2E_EXISTING_HDD_DUPLICATE_PRESEEDED_SD2`
- `Tests/TestingDirs/E2E_EXISTING_HDD_CONFLICT_PRESEEDED_SD1`
- `Tests/TestingDirs/E2E_EXISTING_HDD_CONFLICT_PRESEEDED_SD2`

## Matrix

| ID | Priority | Scenario | Fixture(s) | Command / Harness | Expected | Coverage |
|---|---|---|---|---|---|---|
| E2E-001 | P0 | Baseline verified ingest | `SD_CARD1` | `scripts/release-smoke-test.sh` | `VERIFIED`, no errors, receipt written | Automated |
| E2E-002 | P0 | Baseline verified ingest | `SD_CARD2` | `scripts/release-smoke-test.sh` | `VERIFIED`, no errors, receipt written | Automated |
| E2E-003 | P0 | Idempotent rerun duplicate handling | `SD_CARD1`, `SD_CARD2` | `scripts/release-smoke-test.sh` | second run reports duplicates, no overwrite | Automated |
| E2E-004 | P0 | Mixed-camera full-card inventory (all candidates, no sampling) | runtime-generated fixture | `IngestPreparationServiceTests.testPrepareInventoriesAllCandidatesForMixedCameraRuntimeFixture` | mixed distribution with known/unknown counts from full scan set | Automated (plan-level) |
| E2E-005 | P1 | Unknown camera fallback for videos without usable metadata | runtime-generated fixture | `IngestPreparationServiceTests.testPrepareConsolidatesUnknownCameraFallbackForVideosWithoutUsableMetadata` | `mtime_fallback` date source and `unknown-camera` labeling | Automated (plan-level) |
| E2E-006 | P1 | XML sidecar metadata fallback and companion planning | runtime-generated fixture | `IngestPreparationServiceTests.testPrepareUsesXMLSidecarFallbackAndPlansCompanionTransfer` | sidecar date/camera inference + companion transfer planning | Automated (plan-level) |
| E2E-007 | P1 | Known camera label planning for video ingest | runtime-generated fixture | `IngestPreparationServiceTests.testPreparePlansKnownVideoWithMatchingCameraLabel` | dated bucket path + stable camera folder label | Automated (plan-level) |
| E2E-008 | P1 | EXIF/XMP camera evidence payload mapping | runtime-generated fixture | `IngestPreparationServiceTests.testCameraEvidencePayloadIncludesSelectionRuleAndSourceForGeneratedPhotoFixture` | model and serial evidence source/selection-rule fields present | Automated (plan-level) |
| E2E-013 | P0 | Reject `source == dest` | temp clone | `scripts/e2e-overlap-preflight-test.sh` | fails before ingest writes | Automated |
| E2E-014 | P0 | Reject destination nested in source | temp clone | `scripts/e2e-overlap-preflight-test.sh` | fails before ingest writes | Automated |
| E2E-015 | P0 | Destination disconnect mid-copy/commit | `SD_CARD1` | `scripts/e2e-fault-injection-test.sh` | explicit failed phase (`copy` + `commit`), receipt preserved, no false success | Automated |
| E2E-016 | P0 | Disk full during ingest | `SD_CARD1` | `scripts/e2e-fault-injection-test.sh` | explicit `copy` failure with ENOSPC signal + recoverable receipt/staging | Automated |
| E2E-017 | P0 | Receipt sink failover to local temp | `SD_CARD1` | `scripts/e2e-fault-injection-test.sh` | failover logged, receipt continuity preserved, sink transitions recorded | Automated |
| E2E-018 | P0 | Verify failure halts remaining commit | `SD_CARD1` single-file clone | `scripts/e2e-verify-failure-test.sh` | session fails in verify, no commit-start events, staging retained | Automated |
| E2E-019 | P0 | Source card immutability verification | `SD_CARD1`, `SD_CARD2` | `scripts/release-smoke-test.sh` pre/post manifest+hash diff | no source file/mtime mutations | Automated |
| E2E-020 | P1 | Timestamp preservation on committed files | `SD_CARD1`, `SD_CARD2` | `scripts/e2e-timestamp-and-write-audit-test.sh` | mtime preserved, creation date best-effort | Automated |
| E2E-021 | P1 | Case-only duplicate basename collision across different dirs (different content) | runtime-generated fixture | `IngestPreparationServiceTests.testPrepareResolvesSameBasenameAcrossDifferentDirsWithDeterministicSuffix` | no overwrite, deterministic collision suffix (`-1`) | Automated (plan-level) |
| E2E-022 | P1 | Crash/restart recovery with retained staging | injected crash between verify/commit | `scripts/e2e-crash-restart-recovery-test.sh` | receipt + staging enable deterministic recovery | Automated |
| E2E-023 | P2 | Dry-run truthfulness (never implies verified copy) | `SD_CARD1`, `SD_CARD2` | `scripts/e2e-dry-run-truthfulness-test.sh` | non-verified status labeling + plan-only writes | Automated |
| E2E-024 | P2 | Destination-constrained writes audit | `SD_CARD1`, `SD_CARD2` | `scripts/e2e-timestamp-and-write-audit-test.sh` | writes only under allowed paths (plus fallback receipt path) | Automated |
| E2E-025 | P0 | Organization matrix `YYYY/YYYYMM` + camera + no split | `SD_CARD1`, `SD_CARD2`, `E2E_EXISTING_HDD_*` + runtime-injected RAW/sidecars/known-camera + forced `_unsorted` test paths | `scripts/existing-hdd-e2e-test.sh` | first run + rerun; exact expected paths (known+unknown camera, sidecars, `_unsorted`), receipt `path_scheme`, and hash integrity | Automated |
| E2E-026 | P0 | Organization matrix `YYYY/MM` + camera + no split | `SD_CARD1`, `SD_CARD2`, `E2E_EXISTING_HDD_*` + runtime-injected RAW/sidecars/known-camera + forced `_unsorted` test paths | `scripts/existing-hdd-e2e-test.sh` | first run + rerun; exact expected paths (known+unknown camera, sidecars, `_unsorted`), receipt `path_scheme`, and hash integrity | Automated |
| E2E-027 | P0 | Organization matrix `YYYY/YYYYMM` + no camera + no split | `SD_CARD1`, `SD_CARD2`, `E2E_EXISTING_HDD_*` + runtime-injected RAW/sidecars/known-camera + forced `_unsorted` test paths | `scripts/existing-hdd-e2e-test.sh` | first run + rerun; exact expected paths (camera-folder disabled), sidecars, `_unsorted`, receipt `path_scheme`, and hash integrity | Automated |
| E2E-028 | P0 | Organization matrix `YYYY/YYYYMM` + camera + split RAW | `SD_CARD1`, `SD_CARD2`, `E2E_EXISTING_HDD_*` + runtime-injected RAW/sidecars/known-camera + forced `_unsorted` test paths | `scripts/existing-hdd-e2e-test.sh` | first run + rerun; exact RAW/Non-RAW buckets for photos+photo sidecars, unsplit videos, `_unsorted`, receipt `path_scheme` | Automated |
| E2E-029 | P0 | Organization matrix `YYYY/MM` + no camera + no split | `SD_CARD1`, `SD_CARD2`, `E2E_EXISTING_HDD_*` + runtime-injected RAW/sidecars/known-camera + forced `_unsorted` test paths | `scripts/existing-hdd-e2e-test.sh` | first run + rerun; exact expected paths (camera-folder disabled), sidecars, `_unsorted`, receipt `path_scheme`, and hash integrity | Automated |
| E2E-030 | P0 | Organization matrix `YYYY/MM` + camera + split RAW | `SD_CARD1`, `SD_CARD2`, `E2E_EXISTING_HDD_*` + runtime-injected RAW/sidecars/known-camera + forced `_unsorted` test paths | `scripts/existing-hdd-e2e-test.sh` | first run + rerun; exact RAW/Non-RAW buckets for photos+photo sidecars, unsplit videos, `_unsorted`, receipt `path_scheme` | Automated |
| E2E-031 | P0 | Organization matrix `YYYY/YYYYMM` + no camera + split RAW | `SD_CARD1`, `SD_CARD2`, `E2E_EXISTING_HDD_*` + runtime-injected RAW/sidecars/known-camera + forced `_unsorted` test paths | `scripts/existing-hdd-e2e-test.sh` | first run + rerun; exact paths with split RAW/Non-RAW and no camera folder, plus `_unsorted` paths and receipt `path_scheme` | Automated |
| E2E-032 | P0 | Organization matrix `YYYY/MM` + no camera + split RAW | `SD_CARD1`, `SD_CARD2`, `E2E_EXISTING_HDD_*` + runtime-injected RAW/sidecars/known-camera + forced `_unsorted` test paths | `scripts/existing-hdd-e2e-test.sh` | first run + rerun; exact paths with split RAW/Non-RAW and no camera folder, plus `_unsorted` paths and receipt `path_scheme` | Automated |

`E2E-025`–`E2E-032` note (added 2026-07-14): the `Pass` column above undersells what `existing-hdd-e2e.py` actually checks. Its `prepare_destination()` pre-seeds two kinds of pre-existing files at rollkeep's own computed final path, using the real CLI binary against a real destination tree (not a unit test): (1) byte-identical duplicates (`sd1-duplicate-preseeded`, `sd1-full-duplicate-existing-tree`, and `sd2` equivalents) asserting `duplicateNotCopied`/no re-copy; (2) same-name-different-bytes conflicts (`sd1-conflict-preseeded`, `sd2-conflict-preseeded`) asserting the original is untouched, the new file lands at a deterministic `-1` suffix with a matching hash, and the receipt records `CONFLICT_RENAMED`. This is the real, full-process E2E coverage for `RT-P1-01` in `docs/red-team-ingest-test-matrix.md` — stronger than the `StagingCommitEngineTests` unit coverage cited there, which exercises the identical `resolveCommitPath` logic in isolation. Neither this script nor the unit tests construct a genuine case-only or Unicode-normalization filename collision (real camera-derived fixture filenames don't collide that way); that half of `RT-P1-05` remains unit-only (`DestinationPathPlannerTests`, `StagingCommitEngineTests`) with no dedicated E2E scenario.

| E2E-033 | P0 | Symbolic link skipped, not followed, does not abort import | `SD_CARD1` clone + boundary-escaping file and directory symlinks | `scripts/e2e-symlink-skip-test.sh` | `VERIFIED`, `errors=0`, symlinks not counted as candidates, out-of-bound targets absent from library, source symlinks unchanged, receipt `SCAN_WARNING` (`symbolic_link_skipped`) per link | Automated |
| E2E-034 | P0 | Preflight abort when destination lacks free space | `SD_CARD1` | `scripts/e2e-fault-injection-test.sh` (`ROLLKEEP_TEST_FORCE_INSUFFICIENT_DISK_SPACE`) | explicit `copy`-phase failure with "insufficient free space" message before any `FILE_COPY_STARTED` event; distinguishes proactive preflight check from reactive mid-copy ENOSPC handling (`E2E-016`) | Automated |
| E2E-035 | P1 | Unreadable source file recorded as explicit error, other files unaffected | `SD_CARD1` clone + one `chmod 000` media file | `scripts/e2e-unreadable-source-test.sh` | `VERIFIED` status, `errors=1`, unreadable file excluded from candidates/committed count, other files still committed, receipt `ERROR` event (scan phase) + `SCAN_SUMMARY.error_count=1`, unreadable file left unmodified on source | Automated |
| E2E-036 | P0 | CLI rejects removed `--skip-verify` flag before any ingest work | N/A (argument parsing) | `RollkeepCLIPathSchemeTests.testValidateRejectsRemovedSkipVerifyFlag` | unrecognized-argument failure, non-zero exit, no staging/receipt/library writes | Automated |
| E2E-037 | P1 | Duplicate detection is destination-path-scoped, not library-wide (`RT-P1-08`) | `SD_CARD1` + pre-seeded duplicate at a non-computed path | none yet | re-copy occurs; receipt must not claim duplicate recognition beyond rollkeep's own computed path | Not automated (backlog) |
| E2E-038 | P1 | Concurrent runs against the same destination don't corrupt state (`RT-P1-09`) | `SD_CARD1`, `SD_CARD2` | none yet | per-session isolation holds; no data corruption/overwrite; double-launch not blocked (documented gap) | Not automated (backlog) |
| E2E-039 | P1 | Unicode-normalization filename collision handled safely on real HFS+/exFAT/APFS volumes (`RT-P1-05`, Unicode half) | runtime-generated NFC/NFD-named files, real `hdiutil`-mounted HFS+/exFAT/APFS destinations | `scripts/e2e-unicode-normalization-test.sh` | NFC-named commit, then NFD-named identical content → `duplicate_not_copied=1`, no second file; NFD-named different content → `conflicts_renamed=1`, deterministic `-1` suffix, original byte-unchanged; verified on all 3 filesystems | Automated |
| E2E-040 | P0 | Crafted ISO-BMFF extended box size must not crash the process via an integer-overflow trap (`RT-P0-12`, fixed 2026-07-16) | 24-byte crafted blob (valid `free` box + `moov` box with `size=1` and extended size `UInt64.max`), cloned `SD_CARD1` | `scripts/e2e-boxwalker-overflow-crash-test.sh`; unit-level regression test `ISOBMFFBoxWalkerTests.testGracefullyStopsOnExtendedSizeOverflow` (unconditional, no longer gated) | real CLI binary completes `VERIFIED`, `crash.mp4` committed byte-identically as an ordinary unknown-camera/mtime_fallback candidate, source fixture byte-unchanged | Automated (regression check locking in the fix) |
| E2E-041 | P1 | Unbounded embedded-metadata string must not block a whole run or add real PDF-rendering cost (`RT-P1-10`, fixed 2026-07-16) | raw-bytes `hostile.mp4` (`"Model:" + "A"*N`, extreme N~1.9M and boundary N~200 variants), cloned `SD_CARD1` | `scripts/e2e-metadata-length-bomb-test.sh`; PDF wall-clock benchmarked directly in `Tests/RollKeepEngineTests/PDFReceiptRenderingSupportBenchmarkTests.swift` (opt-in full-size via `ROLLKEEP_REPRODUCE_METADATA_LENGTH_BOMB=1`) | both variants: exit `0`/`VERIFIED`, every file on the card committed (no whole-run-abort), `hostile.mp4` falls back to `unknown-camera` (oversized field rejected by the new 128-byte cap), every path component within the cap, PDF back to normal size (~34KB vs. 209KB pre-fix) | Automated (regression check locking in the fix) |
| E2E-042 | P2 | Hostile source filenames (max-length, RTL-override extension spoofing, control characters) handled safely (`RT-P2-04`) | real `hdiutil`-mounted HFS+ volume with 3 hostile-named files | `scripts/e2e-hostile-filenames-test.sh` | all 3 scanned as candidates, RTL-override file classified as video by its true extension, JSON output has no literal unescaped control bytes | Automated |

## Current Automation Mapping

- Full ingest E2E smoke: `scripts/release-smoke-test.sh`
- Existing-HDD + organization matrix E2E: `scripts/existing-hdd-e2e-test.sh`
- Fault-injection E2E safety checks: `scripts/e2e-fault-injection-test.sh`
- Timestamp + destination-write audit E2E checks: `scripts/e2e-timestamp-and-write-audit-test.sh`
- Crash/restart recovery E2E checks: `scripts/e2e-crash-restart-recovery-test.sh`
- Dry-run truthfulness E2E checks: `scripts/e2e-dry-run-truthfulness-test.sh`
- Overlap preflight E2E checks (`source==dest`, nested dest): `scripts/e2e-overlap-preflight-test.sh`
- Symbolic-link skip-and-warn E2E checks (boundary non-escape): `scripts/e2e-symlink-skip-test.sh`
- App-surface E2E checks (launcher integration): `scripts/app-e2e-launcher-test.sh`
- Box-walker overflow-trap crash reproduction (`RT-P0-12`): `scripts/e2e-boxwalker-overflow-crash-test.sh`
- Unbounded embedded-metadata-string / whole-run-abort / PDF cost (`RT-P1-10`): `scripts/e2e-metadata-length-bomb-test.sh`, `Tests/RollKeepEngineTests/PDFReceiptRenderingSupportBenchmarkTests.swift`
- Hostile source filenames (`RT-P2-04`): `scripts/e2e-hostile-filenames-test.sh`
- Fixture-backed plan/inference matrix: `Tests/rollkeepTests/IngestPreparationServiceTests.swift`
- Core pipeline behavior units (corrected 2026-07-13: moved under `Tests/RollKeepEngineTests/` by the engine-extraction refactor; previously misattributed to `Tests/rollkeepTests/` here):
  - `Tests/RollKeepEngineTests/StagingCopyEngineTests.swift`
  - `Tests/RollKeepEngineTests/StagingCommitEngineTests.swift`
  - `Tests/RollKeepEngineTests/ReceiptWriterTests.swift`
  - `Tests/RollKeepEngineTests/DestinationSpaceCheckerTests.swift`
  - `Tests/rollkeepTests/SourceScannerTests.swift` (still in the CLI test target — not moved)
- CLI argument-surface regression: `Tests/rollkeepTests/RollkeepCLIPathSchemeTests.swift` (`testValidateRejectsRemovedSkipVerifyFlag`, `E2E-036`)

## App-Surface Coverage Mapping

| ID(s) | CLI Harness | App Harness |
|---|---|---|
| E2E-001, E2E-002, E2E-003, E2E-019, E2E-020, E2E-024 | `scripts/release-smoke-test.sh`, `scripts/e2e-timestamp-and-write-audit-test.sh` | `LauncherAppE2ETests.testAppE2EBaselineRerunImmutabilityTimestampsAndWriteAudit` |
| E2E-013, E2E-014 | `scripts/e2e-overlap-preflight-test.sh` | `LauncherAppE2ETests.testAppE2ERejectsOverlappingPathsBeforeStart` |
| E2E-015, E2E-016, E2E-017, E2E-018, E2E-034 | `scripts/e2e-fault-injection-test.sh`, `scripts/e2e-verify-failure-test.sh` | `LauncherAppE2ETests.testAppE2EFaultInjectionScenariosAndFailurePostRunActions` |
| E2E-022 | `scripts/e2e-crash-restart-recovery-test.sh` | `LauncherAppE2ETests.testAppE2ECrashRestartRecoveryAndStopFlow` |
| E2E-025..E2E-032 | `scripts/existing-hdd-e2e-test.sh` | `LauncherAppE2ETests.testAppE2EPathSchemeMatrixAcrossSourcesWithSettingsAndPostRunActions` |
| E2E-023 | `scripts/e2e-dry-run-truthfulness-test.sh` | N/A by design (launcher UI intentionally has no dry-run action) |

Note (corrected 2026-07-13): all test names above are still valid `xcodebuild -only-testing:` selectors, but `LauncherAppE2ETests.swift` itself now holds only shared fixtures/support after a refactor — the actual test bodies live in sibling extension files:
- `testAppE2EBaselineRerunImmutabilityTimestampsAndWriteAudit`, `testAppE2ERejectsOverlappingPathsBeforeStart` → `LauncherAppE2EBaselineTests.swift`
- `testAppE2EFaultInjectionScenariosAndFailurePostRunActions`, `testAppE2ECrashRestartRecoveryAndStopFlow` → `LauncherAppE2EFaultRecoveryTests.swift`
- `testAppE2EPathSchemeMatrixAcrossSourcesWithSettingsAndPostRunActions` → `LauncherAppE2EPathSchemeMatrixTests.swift`
- shared support also split into `LauncherAppE2EAssertionSupport.swift` and `LauncherAppE2ERunSupport.swift`

## Execution Notes

- 2026-03-15: `scripts/release-smoke-test.sh` passed locally with explicit checks for:
  - `E2E-001` / `E2E-002`: `status=completed`, `status_label=VERIFIED`, `errors=0`
  - `E2E-003`: rerun classification `idempotent_rerun` with non-zero `duplicate_not_copied`
  - Receipt continuity: receipt file exists and includes `SESSION_STARTED` + `SESSION_FINISHED`
  - `E2E-019`: source fixture immutability validated via pre/post file manifest diff (path, size, mtime, SHA-256)
- 2026-03-15: `swift test --filter IngestPreparationServiceTests` passed (6/6) after replacing slow large-fixture checks with runtime-generated plan-level scenarios while preserving ROL-6 behavior assertions.
- 2026-03-15: retained EXIF/XMP metadata evidence integration using a generated JPEG+XMP fixture in `IngestPreparationServiceTests.testCameraEvidencePayloadIncludesSelectionRuleAndSourceForGeneratedPhotoFixture`.
- 2026-03-15: collision regression remains covered by `IngestPreparationServiceTests.testPrepareResolvesSameBasenameAcrossDifferentDirsWithDeterministicSuffix` using runtime-generated same-basename files from separate directories (`E2E-021`).
- 2026-03-15: added deterministic receipt failover test `ReceiptWriterTests.testAppendFallsBackToLocalReceiptWhenDestinationAppendFailsMidSession`; verifies destination append failure triggers local temp sink transition with event-index continuity (`E2E-017` partial coverage).
- 2026-03-15: added deterministic verify-failure E2E harness `scripts/e2e-verify-failure-test.sh`; uses a test-only env-gated pre-verify corruption hook to assert verify-phase abort, `committed=0`, no `FILE_COMMIT_STARTED` events, and retained staging (`E2E-018` automated coverage).
- 2026-03-15: added deterministic fault-injection harness `scripts/e2e-fault-injection-test.sh`; covers copy/commit disconnect-style failures (`E2E-015`), ENOSPC-style copy failure (`E2E-016`), and destination->local receipt sink failover continuity (`E2E-017`).
- 2026-03-15: added `scripts/e2e-timestamp-and-write-audit-test.sh` with fixture-backed full ingest assertions for `SD_CARD1` + `SD_CARD2`; validates committed-file timestamp preservation (`E2E-020`) and destination-constrained writes via receipt `touched_paths` + pre/post snapshot diff (`E2E-024`).
- 2026-03-15: added `scripts/e2e-crash-restart-recovery-test.sh` with a test-only verify->commit pause hook and forced process kill; validates retained staging + receipt continuity and deterministic recovery/rerun behavior (`E2E-022`).
- 2026-03-15: added `scripts/e2e-dry-run-truthfulness-test.sh`; validates dry-run status labeling (`DRY RUN (scan+plan)`), `dry_run_not_applicable` idempotency classification, no staged/committed writes, and receipt-only destination writes for `SD_CARD1` + `SD_CARD2` (`E2E-023`).
- 2026-03-15: added `scripts/e2e-overlap-preflight-test.sh`; validates `source == dest` and destination-nested-in-source CLI preflight rejection with no ingest artifacts written (`E2E-013`, `E2E-014`).
- 2026-03-18: expanded `scripts/existing-hdd-e2e.py` into an explicit 8-scheme organization matrix across `SD_CARD1` + `SD_CARD2`; retained deep default-scheme duplicate/conflict/rerun scenarios and added runtime source augmentation with deterministic RAW + sidecar fixtures (`E2E-025`..`E2E-032`).
- 2026-03-18: matrix harness now validates independent destination path structure (`YYYY/YYYYMM` vs `YYYY/MM`, camera folder on/off, RAW split on/off) against created library paths, while still asserting file-hash integrity and no-overwrite behavior.
- 2026-03-18: matrix harness now asserts expected post-import paths for injected files (`E2E_RAW.CR3`, `E2E_RAW.XMP`, `E2E_STD.JPG`, `E2E_STD.XMP`, `E2E_VID.MP4`, `E2E_VID.XML`) including sidecar co-placement and no video compression-segment insertion.
- 2026-03-18: matrix harness now runs first-pass + rerun coverage for all 8 organization schemes across both sources, asserting rerun idempotency (`committed=0`, all duplicates, destination unchanged).
- 2026-03-18: matrix harness now asserts receipt minimum-event evidence (`CAMERA_LABEL_DETECTED`, `DIR_CREATED`) and `path_scheme` parity across `SESSION_STARTED`, `PLAN_COMPUTED`, and `SUMMARY`.
- 2026-03-18: matrix harness now injects deterministic known-camera video+sidecar fixtures (`E2E_KNOWN.MP4`, `E2E_KNOWNM01.XML`) and validates exact known-camera path placement.
- 2026-03-18: matrix harness now covers full-ingest `_unsorted` paths via a test-only env-gated scanner hook (`ROLLKEEP_TEST_FORCE_MISSING_CAPTURE_DATE_RELATIVE_PATHS`) used only in the e2e harness.
- 2026-03-19: existing-HDD CLI E2E now supports fast/full fixture profiles and configurable worker count (`--fixture-profile`, `--workers`), with wrapper defaults `fast + 4 workers`.
- 2026-03-19: launcher app path-scheme matrix test now uses slim source clones plus the existing runtime-augmented files to reduce feedback time while keeping assertions unchanged.
- 2026-07-12: rebuilt `SD_CARD1`/`SD_CARD2` from a richer real-media set via new `scripts/build-e2e-fixtures.py` (reproducible mapping + committed `fixture-manifest.json` + `--check` preflight in `scripts/run-e2e-tests.sh`). Updated the four pinned slim/duplicate/conflict paths across `existing-hdd-e2e.py`, the four non-empty `E2E_EXISTING_HDD_*/fixture.json` files, `LauncherAppE2ETests.swift`, and `e2e-verify-failure-test.sh` to real filenames with honest containers (Sony clips are `.MP4`; only iPhone clips are `.MOV`). Baseline smoke observed: SD_CARD1 `VERIFIED` 10/10 committed, 0 errors; SD_CARD2 `VERIFIED` 27 candidates + 2 sidecars = 29 committed, 0 errors, 12 distinct camera labels, `.GPR`/`.WAV` skipped cleanly, Sony XML + DJI SRT sidecars co-placed.

- 2026-07-12: changed source-scanner symbolic-link handling from hard-abort to skip-and-warn (product decision: a stray alias on an existing-HDD source must not break the whole import). Symlinks are never followed (source-boundary escape still prevented), are reported via a new `SCAN_WARNING` receipt event with category `symbolic_link_skipped`, and are excluded from candidates. Added `scripts/e2e-symlink-skip-test.sh` (`E2E-033`) and rewrote the two `SourceScannerTests` symlink cases to assert skip + boundary non-escape. Removed the now-unreachable `SourceScannerError.symbolicLinkDetected` case and its CLI/launcher failure mappings.

- 2026-07-13: added a proactive preflight disk-space check (`DestinationSpaceChecker`) that runs at the start of the copy phase, before any bytes are written, comparing the exact planned `bytesToCopy` (plus a 5% headroom) against the destination volume's available capacity. On insufficient space it aborts with an `IngestRuntimeError(phase: .copy, ...)` before any `FILE_COPY_STARTED` event (`E2E-034`), unlike the existing reactive `E2E-016` scenario which fails mid-copy. If capacity can't be determined (e.g. unusual filesystem), it fails open with a logged warning and proceeds, relying on the existing reactive ENOSPC handling as a fallback. Added `ROLLKEEP_TEST_FORCE_INSUFFICIENT_DISK_SPACE` fault-injection knob and a new unit test suite `Tests/RollKeepEngineTests/DestinationSpaceCheckerTests.swift`.

- 2026-07-13: automated the previously manual-only `RT-P1-02` red-team scenario ("unreadable source file must be explicit, isolated, and accounted for"). Confirmed `SourceScanner` already handled this correctly (a per-file `isReadable` check at `SourceScanner.swift:116-119` records a non-fatal `ScanErrorRecord` and continues scanning rather than aborting), but it had zero test coverage at any level. Added `scripts/e2e-unreadable-source-test.sh` (`chmod 000` one real media file on a cloned `SD_CARD1`, assert `VERIFIED` + `errors=1` + all other files still committed + receipt `ERROR`/`SCAN_SUMMARY` evidence + the unreadable file left untouched on the source) and a matching unit test `SourceScannerTests.testScanRecordsUnreadableFileAsErrorAndStillScansOtherFiles` (`E2E-035`). [Line citation corrected 2026-07-13 from `115-119` to `116-119`.]
- 2026-07-13: doc audit against current source found the `--skip-verify` CLI flag was fully removed in commit `807d468` (2026-03-21, predates this note) rather than merely hardened. Added `E2E-036` mapping to the existing but previously unmapped `RollkeepCLIPathSchemeTests.testValidateRejectsRemovedSkipVerifyFlag`. Also corrected three stale file-path references in "Current Automation Mapping" (`StagingCopyEngineTests.swift`, `StagingCommitEngineTests.swift`, `ReceiptWriterTests.swift` had moved to `Tests/RollKeepEngineTests/` under the engine-extraction refactor but the doc still pointed at `Tests/rollkeepTests/`), and noted that `LauncherAppE2ETests.swift` was decomposed into per-scenario extension files. Added two new backlog scenarios found via code audit, not yet automated: `E2E-037` (duplicate detection only checks rollkeep's own computed destination path, not the whole library — silent re-copy of files that already exist elsewhere in the destination tree) and `E2E-038` (no lock/PID guard against concurrent runs against the same destination; per-session UUID isolation prevents corruption, but accidental double-launch is undetected and can race the disk-space preflight check). See `RT-P1-08`/`RT-P1-09` in `docs/red-team-ingest-test-matrix.md` for full scenario detail.
- 2026-07-14: closed the Unicode-normalization half of `RT-P1-05`. Rather than assume risk or guess a fix, built real HFS+/exFAT/APFS disk images (`hdiutil`) and confirmed macOS normalizes filenames at the VFS layer on all three, so an NFC-spelled and NFD-spelled version of the same visible filename already resolve to one file via `fileManager.fileExists()` — the existing commit-time hash-compare/collision logic in `StagingCommitEngine.resolveCommitPath` handles this correctly with no code change. Added `scripts/e2e-unicode-normalization-test.sh` (`E2E-039`) to lock this in with the real CLI binary against real volumes of all three filesystems, asserting no overwrite and correct duplicate/conflict-rename outcomes. While building it, also found and fixed an unrelated real bug: `DestinationSpaceChecker` misread `volumeAvailableCapacityForImportantUsage` (an APFS-only purgeable-space concept that exFAT reports as `0` rather than `nil`) as "zero space available," causing every ingest to an exFAT destination to fail preflight regardless of actual free space. Fixed in `Sources/RollKeepEngine/DestinationSpaceChecker.swift:28` to fall back to plain `volumeAvailableCapacity` when the "important usage" figure isn't informative. `swift test` (246/246) and `scripts/e2e-fault-injection-test.sh` (genuine disk-full detection, `E2E-016`) both still pass after the fix.
- 2026-07-15: replaced the video embedded-metadata fallback's reliance on a blind 2MB head + 2MB tail byte-window regex scan with a structured ISO-BMFF box walker (`Sources/RollKeepCore/ISOBMFFBoxWalker.swift`) that reads only box headers, skipping `mdat` via seek instead of reading it. Added a small FourCC-keyed vendor-atom decoder registry (`VideoEmbeddedBoxMetadataResolver.swift`) with decoders for GoPro `moov/udta/GPMF` (binary KLV), DJI `moov/udta/Xtra` (UTF-16LE pseudo key=value blob), and Samsung `moov/udta/smta` (FullBox-nested boxes), plus box-scoped reuse of the existing Sony `NonRealTimeMeta` XML regex for the top-level `meta/xml ` box. The old blind-scan text parser is unchanged and remains the fallback for unrecognized vendors (Canon/Nikon/Fujifilm, anything not yet reverse-engineered); also added an `Insta360` pattern to its existing heuristic regex list, since Insta360's model string sits in a proprietary trailer *after* the ISO-BMFF structure, not in a walkable box. Where a vendor atom yields a bare internal SKU rather than a retail name (DJI's `Xtra` model_name is "AC006", not "DJI Osmo Action 6"), the resolver does one additional narrow lookup scoped to `udta`'s own already-read bytes (not a fresh full-file scan) to prefer the friendlier name when present. Verified zero regressions against all 15 real video fixtures in the local `Tests/TestingDirs` set via a new standing regression tool, `Tests/rollkeepTests/CameraMetadataFixtureRegressionTests.swift` (old-vs-new comparison using an injectable empty decoder registry to reproduce prior behavior on demand). Newly resolved: DJI action-4/6, mini-4-pro, and pocket-3 gain `cameraMake` (model was already correct via the existing heuristic scan); GoPro gains `cameraMake` and `cameraSerial`; Samsung goes from fully `unknown-camera` to `make=Samsung, model=SM-A546B`. Benchmarked (`VideoEmbeddedBoxMetadataResolverBenchmarkTests.swift`, local-only): the 670MB GoPro fixture resolves in ~8ms via the box walk vs ~4.5s via the old blind scan (~550x); files with no known vendor atom (e.g. Insta360, which still falls through to the blind scan) see only ~11ms of added overhead from the box-walk attempt. Re-ran `scripts/existing-hdd-e2e-test.sh` (all scenarios pass) and a manual `SD_CARD2` ingest: distinct camera labels rose from the documented baseline of 12 to 14 (the two newly-resolved cases above plus Insta360), with zero `unknown-camera` output. Separately discovered but deliberately deferred: `EmbeddedVideoMetadataTextParser.parse()`'s ~20-pattern regex sweep over a multi-megabyte text window costs ~2.5s on real fixtures — pre-existing behavior for any file that already fell through to the blind-scan fallback, not a regression introduced here. One safe, behavior-preserving fix applied (cache the O(n) `NSRange` conversion per call instead of per-regex); the larger fix is out of scope for this change (tier 4 was intentionally left "unchanged in mechanism") and tracked separately.
- 2026-07-15: extended the box-walk decoders above to the fast preview scan (`SourceScanner`'s `previewVideoMetadataExtractor`, used by the Launcher app's live source-picker UI), which previously used `embeddedFallbackMode: .disabled` -- skipping vendor-atom decoding entirely, not just the slow blind scan -- because the only fallback available at the time (the blind 2MB/2MB scan) was too slow for a live UI. Added a new `EmbeddedFallbackMode.structuredOnly` case: box-walk vendor-atom decoding runs, but the blind text scan never does. Verified via a full preview-mode scan of the entire local fixture tree (38 photo+video candidates): unresolved (`unknown`) camera count dropped from 11 to 2 (the remaining 2 are Insta360, whose fix lives entirely in the blind scan tier, and one non-video fixture unrelated to this change), for a total scan-time cost of ~350ms across all 38 files -- most of that being the bounded, udta-scoped "friendlier model name" lookup for the 4 DJI files, not the box walk itself. `.deep` mode (the real ingest scan) is unaffected; existing tests that inject their own stub `previewVideoMetadataExtractor` (`SourceScannerTests.testPreviewScanUsesPreviewVideoMetadataExtractor`, `LauncherCoreViewModelBehaviorTests`) are unaffected since they override the default. Re-ran `scripts/existing-hdd-e2e-test.sh` (all scenarios pass) and the full `swift test` suite (302/302, same 5 pre-existing skips).
- 2026-07-15: found and fixed a camera-folder consistency bug surfaced by the two changes above: photo EXIF `Model` is always a vendor's bare internal code (confirmed via real fixtures, e.g. DJI's hidden `ExifIFD:UniqueCameraModel` tag reads `"DJI AC003 OsmoAction4"`, but the plain `Model` field is just `"AC003"`), while some video paths resolve to a friendlier product name instead (`"DJI OsmoAction4"`) -- so photos and videos from the *same physical camera* were landing in different camera folders. Confirmed empirically across all camera/media-type pairs in the local fixture set: GoPro and both Sony cases already matched by coincidence (video resolves to the exact same string as photo EXIF), but all 3 DJI product lines and Samsung did not. Fixed at the existing per-vendor label-normalization layer (`CameraIdentityLabelNormalizer.swift`, alongside the existing `StripDJIManufacturerPrefixRule`/`StripIPhoneLensVariantSuffixRule`) rather than by changing either metadata source: added `MapKnownModelCodeToProductNameRule`, a small hand-verified lookup table (`AC003`/`AC006`/`FC8482`/`PP-101` -> `OsmoAction4`/`OsmoAction6`/`Mini4 Pro`/`OsmoPocket3`; `SM-A546B` -> `Galaxy A54 5G`) that runs before the existing rules, so whichever vocabulary either media type happens to produce converges on one label. Samsung's pairing (`SM-A546B` <-> `Galaxy A54 5G`) has no shared substring in either file -- unlike DJI, it's a hand-curated mapping with no way to derive or verify it from file contents alone, so it's scoped to only the one model seen in fixtures; unrecognized codes pass through unchanged (same safe-default behavior as the existing heuristic regex lists). Verified via a real-fixture check computing both the photo-path and video-path `CameraLabeler` output for the same physical camera: all 6 available pairs (DJI action-4/mini-4-pro/pocket-3, Samsung, GoPro, Sony a7c2) now produce identical labels. `swift test` (305/305, same 5 pre-existing skips) and `scripts/existing-hdd-e2e-test.sh` both still pass.
- 2026-07-16: new-attack-surface audit pass, focused on adversarial *content* crafted to break the hand-rolled metadata parsers (as opposed to real-world fault conditions, the focus of everything above). Two confirmed issues, both new matrix entries in `docs/red-team-ingest-test-matrix.md`:
  - `RT-P0-12`/`E2E-040`: `ISOBMFFBoxWalker.readBoxes` reads a box's 64-bit extended size as a raw attacker-controlled value with no upper bound, then does a checked `UInt64` addition that traps (crashes the process) on overflow. Confirmed both at the unit level (`ISOBMFFBoxWalkerTests.testExtendedSizeOverflowTrapsProcess`, gated behind `ROLLKEEP_REPRODUCE_BOXWALKER_OVERFLOW_CRASH=1` since a trap kills the whole `swift test` process) and against the real CLI binary (`scripts/e2e-boxwalker-overflow-crash-test.sh`): `Process ... exited with unexpected signal code 5` (SIGTRAP). Reachable via the Launcher's live card-preview scan with no ingest action at all, not just the CLI deep scan.
  - `RT-P1-10`/`E2E-041`: `EmbeddedVideoMetadataTextParser`'s regex captures (e.g. `Model\s*[:=]\s*([^\r\n<]+)`) have no max-length bound, so a crafted "Model:" field survives two independent uncapped sanitizers (`CameraLabeler.slug()`, `DestinationPathPlanner.sanitizeCameraLabel`) as a single unbroken token. Confirmed via `scripts/e2e-metadata-length-bomb-test.sh` against the real CLI: an oversized label doesn't just fail its own file -- `StagingCopyEngine`/`StagingCommitEngine`'s first-failure-cancels-all design means it aborts the whole run (exit `5`/`copyFailed`, `committed=0` of otherwise-good files on the card). PDF rendering cost measured directly in `PDFReceiptRenderingSupportBenchmarkTests.swift`: confirmed linear, not the quadratic hypothesis first suspected (~7s at 1M chars, ~11.5s at the real ~1.9MB worst case via a "Camera Distribution" reachability path that needs no filesystem interaction at all, even under `--dry-run`).
  - Also time-boxed a secondary check, `RT-P2-04`/`E2E-042` (hostile filenames: max-length, RTL-override extension spoofing, control characters) via `scripts/e2e-hostile-filenames-test.sh` -- ran on HFS+ rather than exFAT after this environment's exFAT/FAT-family `hdiutil` driver proved persistently unreliable (5+ retries with backoff still failed, while HFS+ succeeded every time); the scanning/classification/output-escaping logic under test has no filesystem-specific branches, so the substitution doesn't weaken what's verified. No new issue found beyond a minor display-only finding (a raw U+202E override character reaches human-mode terminal output unescaped).
  - Also confirmed via direct code reading, no new issues: the DJI/Samsung/GoPro vendor box decoders are all properly length/depth-bounded (unlike the regex text parser); the `378d4d4` symlink hard-abort-to-skip-and-warn softening did not regress the fail-closed no-follow/no-escape guarantee (dated re-confirmation note added to `RT-P1-07`).
  - Intentionally out of scope for this pass (per user direction): `RT-P1-08`, `RT-P1-09`, and the still-open 2026-03-11 ISO audit findings (sensitive identifiers in receipts, launcher `UserDefaults` retention) -- not re-investigated.
  - All new benchmark/PoC tests are opt-in gated (env vars) or sized down by default so the baseline `swift test` run stays fast and green (308/308, 7 pre-existing+1 new skip, ~39s, unchanged from before this pass).
  - Both confirmed issues were fixed the same day, at the user's request. `RT-P0-12`: `ISOBMFFBoxWalker.readBoxes`'s `offset + boxSize` check now uses `offset.addingReportingOverflow(boxSize)` and treats an overflow like any other malformed/oversized box (stop instead of guessing); the unit-level PoC (`testExtendedSizeOverflowTrapsProcess`) was un-gated and renamed to `testGracefullyStopsOnExtendedSizeOverflow` now that it no longer crashes, and `scripts/e2e-boxwalker-overflow-crash-test.sh`'s expectation was flipped to assert a clean `VERIFIED` exit. `RT-P1-10`: `EmbeddedVideoMetadataTextParser`'s shared `sanitize()` helper (used by every extracted make/model/serial value from this parser) now rejects any value over 128 UTF-8 bytes, matching the existing `DJIXtraMetadataDecoder.maxModelCodeUnits` precedent; `scripts/e2e-metadata-length-bomb-test.sh` was flipped to assert both variants complete `VERIFIED` with the whole card committed and `hostile.mp4` falling back to `unknown-camera`. Both fixes re-verified against the full `swift test` suite (310/310 green) and a real CLI run against `Tests/TestingDirs/SD_CARD1`/`SD_CARD2` matching the documented baseline exactly (0 errors, same counts) -- confirming zero behavior change for legitimate media. See `RT-P0-12`/`RT-P1-10` in `docs/red-team-ingest-test-matrix.md` for full before/after detail.

## Known Coverage Gaps (spec requirements with no matrix row)

Identified 2026-07-13 via a full cross-check against `docs/ROL-6-spec-and-invariants.md`. None of these have a red-team or E2E row yet; listed here so they aren't lost. Roughly ordered by user-harm relevance:

1. Embedded EXIF/container metadata preservation (spec §3) — only implied by whole-file hash/size equality and filesystem-timestamp checks (`E2E-020`), never asserted directly on metadata tags.
2. Capture-date priority ordering (spec §5) — matrix rows cover only the terminal mtime-fallback/sidecar cases (`E2E-005`, `E2E-006`); the rule that a higher-priority source (e.g. EXIF `DateTimeOriginal`) wins when multiple sources are present is untested.
3. Metadata-extraction failure on a readable-but-corrupt file (spec §9) — distinct from the already-covered unreadable-file case (`RT-P1-02`/`E2E-035`).
4. Sidecar extension allowlist (spec §5) — fixtures exercise only `.XML`/`.SRT`; `.THM`, `.XMP`, `.AAE`, `.CPI`, `.NKSC`, `.DOP`, `.PP3`, `.JSON` are untested.
5. Path-strategy snapshot lock during a run (spec §3, §11) — no row exercises a mid-run path-strategy change.
6. Optional finalized JSON summary file (spec §4, `<DEST>/_ingest_receipts/<SessionID>.json`) — existence/contents never asserted.
7. Receipt `touched_paths` with cleanup explicitly enabled (spec §10) — `StagingSessionCleanup` has unit tests but no red-team/E2E row.
8. Timezone policy (spec §5) — only unit-tested (`Tests/rollkeepTests/ExifDateParserTests.swift`), not in either matrix.
9. No camera-serial tokens in folder labels (spec §6) — label format itself is unit-tested in `CameraLabelerTests.swift` but unmapped in either matrix.
10. No confidence-score/warning text in card inventory output (spec §6) — negative assertion, no row checks for its absence.

Not a fixture/test gap, just flagged for completeness: the spec's unnumbered "product note" on capability separation (app-only workflows) is architectural and likely not meant to be a testable row.

## Future Fixture Work

- Reduce fixture video sizes with ffmpeg. The cards total ~1.8 GB, dominated
  by video (largest: 639 MB GoPro `GX010645.MP4`, 135 MB iPhone
  `IMG_0245.MOV`); a full suite run performs roughly 25–30 full-tree
  traversals/copies. Clips could be shortened (e.g. `ffmpeg -t 2 -i in.MP4
  -c copy -map_metadata 0 out.MP4`), but any rewrite must preserve the
  metadata the scanner extracts — QuickTime creation date and Make/Model
  atoms (ImageIO/AVFoundation, plus Sony embedded metadata used for camera
  labeling) — and each shrunken file must be re-verified against the scanner
  (same capture date, same camera label, still `VERIFIED` with 0 errors)
  before swapping it into the source set. Not done yet; tracked here.
