# E2E Ingest Matrix (Tests)

Status: active test matrix for fixture-backed end-to-end safety checks  
Last updated: 2026-07-12  
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
10. `scripts/app-e2e-launcher-test.sh`
11. `scripts/package-macos-app.sh --version $(cat VERSION)`

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

## Current Automation Mapping

- Full ingest E2E smoke: `scripts/release-smoke-test.sh`
- Existing-HDD + organization matrix E2E: `scripts/existing-hdd-e2e-test.sh`
- Fault-injection E2E safety checks: `scripts/e2e-fault-injection-test.sh`
- Timestamp + destination-write audit E2E checks: `scripts/e2e-timestamp-and-write-audit-test.sh`
- Crash/restart recovery E2E checks: `scripts/e2e-crash-restart-recovery-test.sh`
- Dry-run truthfulness E2E checks: `scripts/e2e-dry-run-truthfulness-test.sh`
- Overlap preflight E2E checks (`source==dest`, nested dest): `scripts/e2e-overlap-preflight-test.sh`
- App-surface E2E checks (launcher integration): `scripts/app-e2e-launcher-test.sh`
- Fixture-backed plan/inference matrix: `Tests/rollkeepTests/IngestPreparationServiceTests.swift`
- Core pipeline behavior units:
  - `Tests/rollkeepTests/StagingCopyEngineTests.swift`
  - `Tests/rollkeepTests/StagingCommitEngineTests.swift`
  - `Tests/rollkeepTests/ReceiptWriterTests.swift`
  - `Tests/rollkeepTests/SourceScannerTests.swift`

## App-Surface Coverage Mapping

| ID(s) | CLI Harness | App Harness |
|---|---|---|
| E2E-001, E2E-002, E2E-003, E2E-019, E2E-020, E2E-024 | `scripts/release-smoke-test.sh`, `scripts/e2e-timestamp-and-write-audit-test.sh` | `LauncherAppE2ETests.testAppE2EBaselineRerunImmutabilityTimestampsAndWriteAudit` |
| E2E-013, E2E-014 | `scripts/e2e-overlap-preflight-test.sh` | `LauncherAppE2ETests.testAppE2ERejectsOverlappingPathsBeforeStart` |
| E2E-015, E2E-016, E2E-017, E2E-018 | `scripts/e2e-fault-injection-test.sh`, `scripts/e2e-verify-failure-test.sh` | `LauncherAppE2ETests.testAppE2EFaultInjectionScenariosAndFailurePostRunActions` |
| E2E-022 | `scripts/e2e-crash-restart-recovery-test.sh` | `LauncherAppE2ETests.testAppE2ECrashRestartRecoveryAndStopFlow` |
| E2E-025..E2E-032 | `scripts/existing-hdd-e2e-test.sh` | `LauncherAppE2ETests.testAppE2EPathSchemeMatrixAcrossSourcesWithSettingsAndPostRunActions` |
| E2E-023 | `scripts/e2e-dry-run-truthfulness-test.sh` | N/A by design (launcher UI intentionally has no dry-run action) |

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
