# E2E Ingest Matrix (Tests)

Status: active test matrix for fixture-backed end-to-end safety checks  
Last updated: 2026-03-15  
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
3. `scripts/package-macos-app.sh --version $(cat VERSION)`

## Fixture Inventory Used For E2E

- `Tests/TestingDirs/SD_CARD1`
- `Tests/TestingDirs/SD_CARD2`
- `Tests/TestingDirs/DUPLICATES/SOURCE1`
- `Tests/dji-metadata`
- `Tests/no-video-metadata`
- `Tests/normalize-camera-models`
- `Tests/sony-video`
- `Tests/unknown-tag`
- `Tests/video-sidecars`
- `Tests/bug-unsorted`
- `Tests/bug-duplicate-different-dirs`

## Matrix

| ID | Priority | Scenario | Fixture(s) | Command / Harness | Expected | Coverage |
|---|---|---|---|---|---|---|
| E2E-001 | P0 | Baseline verified ingest | `SD_CARD1` | `scripts/release-smoke-test.sh` | `VERIFIED`, no errors, receipt written | Automated |
| E2E-002 | P0 | Baseline verified ingest | `SD_CARD2` | `scripts/release-smoke-test.sh` | `VERIFIED`, no errors, receipt written | Automated |
| E2E-003 | P0 | Idempotent rerun duplicate handling | `SD_CARD1`, `SD_CARD2` | `scripts/release-smoke-test.sh` | second run reports duplicates, no overwrite | Automated |
| E2E-004 | P0 | Single-camera full-card inventory | `SD_CARD1` | `IngestPreparationServiceTests.testPrepareInventoriesSingleCameraForSDCard1Fixture` | one label, correct counts, no `_unsorted` | Automated (plan-level) |
| E2E-005 | P0 | Mixed-camera full-card inventory | `SD_CARD2` | `IngestPreparationServiceTests.testPrepareInventoriesAllCameraLabelsForSDCard2Fixture` | mixed label distribution, correct counts, no `_unsorted` | Automated (plan-level) |
| E2E-006 | P1 | DJI mixed-label photo card | `dji-metadata` | `IngestPreparationServiceTests.testPrepareUsesDJIMetadataFixtureForMixedCameraDistribution` | model-specific labels + counts | Automated (plan-level) |
| E2E-007 | P1 | Video missing metadata mtime fallback | `no-video-metadata` | `IngestPreparationServiceTests.testPrepareUsesMtimeFallbackForNoVideoMetadataFixture` | `mtime_fallback` date source, `unknown-camera` | Automated (plan-level) |
| E2E-008 | P1 | Sony MP4 metadata label inference | `sony-video` | `IngestPreparationServiceTests.testPrepareDetectsSonyVideoFixtureCameraLabel` | camera label `ilce-7cm2` | Automated (plan-level) |
| E2E-009 | P1 | Sidecar companion detection and planning | `video-sidecars` | `IngestPreparationServiceTests.testPrepareUsesRealVideoSidecarFixturesForSonyXMLAndTHM` | `.THM` + `M01.XML` companions planned with media | Automated (plan-level) |
| E2E-010 | P1 | Unknown tag handling (no generic token labels) | `unknown-tag` | `IngestPreparationServiceTests.testPrepareAvoidsGenericVideoTokenLabelsForUnknownTagFixture` | `unknown-camera` assignment for both videos | Automated (plan-level) |
| E2E-011 | P1 | Historical unsorted regression guard | `bug-unsorted` | `IngestPreparationServiceTests.testPrepareKeepsBugUnsortedFixtureInDatedBucketsViaFallback` | files bucketed to dated folders, no spurious `_unsorted` | Automated (plan-level) |
| E2E-012 | P1 | Sony XML companion expansion on larger card | `DUPLICATES/SOURCE1` | `IngestPreparationServiceTests.testPrepareIncludesSonyXMLCompanionFilesForDuplicatesSource1Fixture` | media + XML companions included in plan | Automated (plan-level) |
| E2E-013 | P0 | Reject `source == dest` | temp clone | CLI preflight | fails before ingest writes | Automated (VolumeResolver tests) + Manual E2E pending |
| E2E-014 | P0 | Reject destination nested in source | temp clone | CLI preflight | fails before ingest writes | Automated (VolumeResolver tests) + Manual E2E pending |
| E2E-015 | P0 | Destination disconnect mid-copy/commit | `SD_CARD1` | `scripts/e2e-fault-injection-test.sh` | explicit failed phase (`copy` + `commit`), receipt preserved, no false success | Automated |
| E2E-016 | P0 | Disk full during ingest | `SD_CARD1` | `scripts/e2e-fault-injection-test.sh` | explicit `copy` failure with ENOSPC signal + recoverable receipt/staging | Automated |
| E2E-017 | P0 | Receipt sink failover to local temp | `SD_CARD1` | `scripts/e2e-fault-injection-test.sh` | failover logged, receipt continuity preserved, sink transitions recorded | Automated |
| E2E-018 | P0 | Verify failure halts remaining commit | `SD_CARD1` single-file clone | `scripts/e2e-verify-failure-test.sh` | session fails in verify, no commit-start events, staging retained | Automated |
| E2E-019 | P0 | Source card immutability verification | `SD_CARD1`, `SD_CARD2` | `scripts/release-smoke-test.sh` pre/post manifest+hash diff | no source file/mtime mutations | Automated |
| E2E-020 | P1 | Timestamp preservation on committed files | `SD_CARD1`, `SD_CARD2` | full ingest + stat checks | mtime preserved, creation date best-effort | Pending |
| E2E-021 | P1 | Case-only duplicate basename collision across different dirs (different content) | `bug-duplicate-different-dirs` | `IngestPreparationServiceTests.testPrepareResolvesSameBasenameAcrossDifferentDirsWithDeterministicSuffix` | no overwrite, deterministic collision suffix (`-1`) | Automated (plan-level) |
| E2E-022 | P1 | Crash/restart recovery with retained staging | injected crash between verify/commit | kill process + rerun | receipt + staging enable deterministic recovery | Pending |
| E2E-023 | P2 | Dry-run truthfulness (never implies verified copy) | `SD_CARD1`, `SD_CARD2` | `--dry-run --json` | non-verified status labeling + plan-only writes | Partial |
| E2E-024 | P2 | Destination-constrained writes audit | `SD_CARD1`, `SD_CARD2` | fs snapshot diff around run | writes only under allowed paths (plus fallback receipt path) | Pending |

## Current Automation Mapping

- Full ingest E2E smoke: `scripts/release-smoke-test.sh`
- Fault-injection E2E safety checks: `scripts/e2e-fault-injection-test.sh`
- Fixture-backed plan/inference matrix: `Tests/rollkeepTests/IngestPreparationServiceTests.swift`
- Core pipeline behavior units:
  - `Tests/rollkeepTests/StagingCopyEngineTests.swift`
  - `Tests/rollkeepTests/StagingCommitEngineTests.swift`
  - `Tests/rollkeepTests/ReceiptWriterTests.swift`
  - `Tests/rollkeepTests/SourceScannerTests.swift`

## Execution Notes

- 2026-03-15: `scripts/release-smoke-test.sh` passed locally with explicit checks for:
  - `E2E-001` / `E2E-002`: `status=completed`, `status_label=VERIFIED`, `errors=0`
  - `E2E-003`: rerun classification `idempotent_rerun` with non-zero `duplicate_not_copied`
  - Receipt continuity: receipt file exists and includes `SESSION_STARTED` + `SESSION_FINISHED`
  - `E2E-019`: source fixture immutability validated via pre/post file manifest diff (path, size, mtime, SHA-256)
- 2026-03-15: `swift test --filter IngestPreparationServiceTests` passed (14/14), reaffirming automated plan-level coverage for `E2E-004` through `E2E-012`.
- 2026-03-15: added fixture-backed collision regression `IngestPreparationServiceTests.testPrepareResolvesSameBasenameAcrossDifferentDirsWithDeterministicSuffix` using `Tests/bug-duplicate-different-dirs`; full `IngestPreparationServiceTests` now passes (14/14) and covers `E2E-021` at plan level.
- 2026-03-15: added deterministic receipt failover test `ReceiptWriterTests.testAppendFallsBackToLocalReceiptWhenDestinationAppendFailsMidSession`; verifies destination append failure triggers local temp sink transition with event-index continuity (`E2E-017` partial coverage).
- 2026-03-15: added deterministic verify-failure E2E harness `scripts/e2e-verify-failure-test.sh`; uses a test-only env-gated pre-verify corruption hook to assert verify-phase abort, `committed=0`, no `FILE_COMMIT_STARTED` events, and retained staging (`E2E-018` automated coverage).
- 2026-03-15: added deterministic fault-injection harness `scripts/e2e-fault-injection-test.sh`; covers copy/commit disconnect-style failures (`E2E-015`), ENOSPC-style copy failure (`E2E-016`), and destination->local receipt sink failover continuity (`E2E-017`).

## Next Recommended Additions

1. Add post-ingest filesystem assertions for destination-constrained writes (`E2E-024`) using pre/post snapshot allowlist checks.
2. Add end-to-end timestamp preservation checks from source to committed final paths (`E2E-020`).
3. Add crash/restart recovery harness that validates deterministic resume with retained staging and receipt (`E2E-022`).
