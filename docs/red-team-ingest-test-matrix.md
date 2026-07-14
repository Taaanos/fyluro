# Red Team Ingest Test Matrix

Status: working test plan + current spot-check results
Last updated: 2026-07-13
Scope: CLI ingest safety, truthfulness, and user-harm prevention

## Goal
The red-team objective is not only "do not destroy files." The stricter question is:

- Can the app ever modify the source card?
- Can it ever overwrite or misplace library files?
- Can it ever tell the user a run is safe when it is not?
- Can it fail in a way that leaves the user unable to recover?
- Can a normal but stressed user make a believable mistake that the app should have blocked?

This plan is grounded in the MVP invariants:

- no delete on card
- no overwrite in library
- staging-first copy flow
- receipt always written
- destination-constrained writes only

## Fixture Baseline

Fixtures were rebuilt on 2026-07-12 from a richer real-media set via
`scripts/build-e2e-fixtures.py` (see `Tests/e2e-ingest-matrix.md` for the
mapping and rebuild instructions). Note: the automated E2E harnesses compute
all count assertions dynamically from the scan plan; the counts below are
observed reference baselines for manual spot checks, not values wired into
the automation.

### `Tests/TestingDirs/SD_CARD1` (Apple phone card)
- Fixture profile: 10 candidates (6 photos, 4 videos), ~318 MB
- Observed on 2026-07-12: baseline ingest `VERIFIED`, `errors = 0`
- Rerun result on same destination: `idempotent_rerun`, `committed = 0`, `duplicate_not_copied = 10`
- Includes a PNG screenshot without camera EXIF (`unknown-camera` label)

### `Tests/TestingDirs/SD_CARD2` (mixed multi-camera card)
- Fixture profile: 27 candidates (17 photos, 10 videos) + 2 transferable
  sidecars (Sony `M01.XML`, DJI `.SRT`) + 2 `.GPR` and 1 `.WAV`
  intentionally skipped companions; ~1.5 GB
- Observed on 2026-07-12: baseline ingest `VERIFIED`, `copied = verified = committed = 29`, `errors = 0`
- Rerun result on same destination: `idempotent_rerun`, `committed = 0`, `duplicate_not_copied = 29` (sidecars are counted as duplicates too)
- Additional observed behavior: 12 distinct camera labels including
  `unknown-camera`; several MP4s without top-level Make/Model resolve labels
  via embedded metadata or fall back to `mtime_fallback`/`unknown-camera`

### Current Spot-Check Findings
- Resolved on 2026-03-10: `source == dest` is rejected at preflight with exit code `1`, and the temp source clone remained free of ingest artifacts.
- Resolved on 2026-03-10: destination nested inside source is rejected at preflight with exit code `1`, and no ingest folders were created inside the source tree.
- Resolved on 2026-07-12 (fixture rebuild): the `SD_CARD2` fixture-drift note previously here (`16`/`13`/`3` candidates) is obsolete. `SD_CARD2` now scans consistently as 27 candidates (17 photos, 10 videos) + 2 sidecars, matching the `Fixture Baseline` section above and confirmed against the committed `fixture-manifest.json` on 2026-07-13. Neither the old `16`/`13`/`3` nor the older `21`/`17`/`4` baseline should be used for release sign-off.
- Resolved on 2026-03-21 (commit `807d468`): the `--skip-verify` command-surface spec gap is closed. The flag was deleted from the CLI entirely rather than hardened; supplying it now fails argument parsing before any ingest work starts. See the rewritten `RT-P0-10` below.

## Priority Legend
- `P0`: safety invariant or false-success risk; user could lose originals or trust a bad ingest
- `P1`: serious correctness or recoverability risk; user can be misled or forced into manual repair
- `P2`: lower-severity friction, confusing behavior, or edge-case robustness issue

## Test Matrix

### `RT-P0-01` Baseline verified ingest on `SD_CARD1`
- Fixture: `Tests/TestingDirs/SD_CARD1`
- Destination: fresh temp directory
- Run: `.build/debug/rollkeep --source <SD_CARD1> --dest <DEST> --json`
- Pass:
  - exit code `0`
  - `status_label == VERIFIED`
  - `candidates = 10`, `photos = 6`, `videos = 4`
  - `copied = 10`, `verified = 10`, `committed = 10`, `errors = 0`
  - receipt exists under `<DEST>/_ingest_receipts`
  - session staging directory is removed after success
- Fail / user harm:
  - misleading camera inventory before card format
  - silent missing file or partial copy
- Observed 2026-07-12: pass (rebuilt fixture)

### `RT-P0-02` Baseline verified ingest on `SD_CARD2`
- Fixture: `Tests/TestingDirs/SD_CARD2`
- Destination: fresh temp directory
- Run: `.build/debug/rollkeep --source <SD_CARD2> --dest <DEST> --json`
- Pass:
  - exit code `0`
  - `status_label == VERIFIED`
  - `candidates = 27`, `photos = 17`, `videos = 10`
  - `copied = 29`, `verified = 29`, `committed = 29`, `errors = 0` (includes 2 transferable sidecars)
  - receipt exists under `<DEST>/_ingest_receipts`
  - fallback metadata events are recorded for videos using `mtime_fallback`
- Fail / user harm:
  - user believes mixed media card is fully protected when it is not
  - video placement may become silently wrong if fallback is not disclosed
- Observed 2026-07-12: pass (rebuilt fixture)

### `RT-P0-03` Idempotent rerun must never overwrite or duplicate-library-copy
- Fixtures: `Tests/TestingDirs/SD_CARD1`, `Tests/TestingDirs/SD_CARD2`
- Destination: reuse the successful destination from `RT-P0-01` or `RT-P0-02`
- Run: repeat the same ingest command against the same destination
- Pass:
  - exit code `0`
  - `idempotency.classification == idempotent_rerun`
  - `committed = 0`
  - `duplicate_not_copied = 10` for `SD_CARD1`
  - `duplicate_not_copied = 29` for `SD_CARD2`
  - no final file contents change
  - no `-1`, `-2`, ... conflict files are created for true duplicates
- Fail / user harm:
  - library bloat
  - accidental overwrite or hidden duplicate proliferation
- Observed 2026-07-12: pass on both cards (rebuilt fixtures)

### `RT-P0-04` Source tree must remain byte-for-byte unchanged after normal ingest
- Fixtures: `Tests/TestingDirs/SD_CARD1`, `Tests/TestingDirs/SD_CARD2`
- Mutation: none
- Run:
  - capture a source manifest before ingest: file list, sizes, mtimes, and SHA-256
  - run a normal ingest to a separate destination
  - capture the same manifest after ingest
- Pass:
  - manifests are identical
  - no new files or directories exist under source
  - source mtimes do not change
- Fail / user harm:
  - source/card modified despite "no delete on card"
  - user may format a card whose contents were already altered by the tool

### `RT-P0-05` Reject `source == dest` before any write
- Fixture: temp clone of `Tests/TestingDirs/SD_CARD1`
- Mutation: `cp -R <SD_CARD1> <SD1_CLONE>`
- Run: `.build/debug/rollkeep --source <SD1_CLONE> --dest <SD1_CLONE> --json`
- Pass:
  - command fails before scan-to-copy transition or at explicit preflight
  - no created library directories under source
  - no receipt written into source tree
  - failure explains that source and destination must be disjoint
- Fail / user harm:
  - app writes into the source/card it is supposed to preserve
  - future reruns may ingest self-generated output
- Observed 2026-03-10: pass; current CLI exits `1` with a preflight overlap-path error and creates no ingest artifacts inside the source clone

### `RT-P0-06` Reject destination nested inside source
- Fixture: temp clone of `Tests/TestingDirs/SD_CARD1`
- Mutation: set destination to `<SD1_CLONE>/backup-dest`
- Run: `.build/debug/rollkeep --source <SD1_CLONE> --dest <SD1_CLONE>/backup-dest --json`
- Pass:
  - command fails at preflight
  - no destination folders are created inside source
  - user sees a clear overlap-path error
- Fail / user harm:
  - source tree is polluted by app output
  - later scans can re-ingest library files as if they were source media
- Observed 2026-03-10: pass; current CLI exits `1` with a preflight overlap-path error and does not create ingest artifacts inside the source tree

### `RT-P0-07` Destination disconnect or permission loss mid-run must fail truthfully
- Preferred fixture: `Tests/TestingDirs/SD_CARD2` because it has more files and a longer copy window
- Mutation: use removable media, sparse disk image, or a harness that revokes destination access during copy or commit
- Pass:
  - non-zero exit
  - failure phase is explicit (`copy` or `commit`)
  - already-written receipt content is preserved
  - staging remains for recovery
  - no false `VERIFIED`
- Fail / user harm:
  - partial library state with no trustworthy audit trail
  - user may format the card because the app looked successful enough

### `RT-P0-08` Disk full mid-copy must fail with no silent truncation
- Preferred fixture: `Tests/TestingDirs/SD_CARD2`
- Mutation: destination capacity smaller than total bytes; use a small sparse image or quota-limited destination
- Pass:
  - non-zero exit in `copy` or `commit`
  - receipt survives and records the failing path
  - truncated files are never reported as verified
  - already-existing library files are untouched
- Fail / user harm:
  - corrupted final files mistaken for successful ingest
  - unrecoverable uncertainty about which files are safe

### `RT-P0-09` Receipt failover must preserve forensic traceability
- Fixtures: `Tests/TestingDirs/SD_CARD1`, `Tests/TestingDirs/SD_CARD2`
- Mutation: make destination receipt path unavailable while destination itself remains otherwise usable
- Pass:
  - local temp receipt fallback is created
  - sink transition is recorded in receipt summary
  - session continues if possible, or fails with receipt path preserved
  - no event history is lost after failover
- Fail / user harm:
  - the exact run that failed is the one with no evidence
  - support and recovery become guesswork

### `RT-P0-10` Verification must never be skippable, including via a removed-but-guessable flag
- Fixture: `Tests/TestingDirs/SD_CARD1`
- Run: `.build/debug/rollkeep --source <SD_CARD1> --dest <DEST> --skip-verify --json`
- Pass:
  - command fails at argument parsing (unrecognized flag), before scan/copy/commit start
  - non-zero exit code
  - no staging, no receipt, no library writes
  - no code path anywhere in the CLI or engine can mark a session `VERIFIED`/`COMPLETED` without every committed file passing verification
- Fail / user harm:
  - user interprets a non-verified copy as safe to format
- Observed 2026-03-10 (superseded): current CLI did not print `VERIFIED`, returned `COMPLETED (verification skipped)`, and the flag conflicted with the MVP spec.
- Observed 2026-03-21 (commit `807d468`, current behavior): `--skip-verify` and its plumbing were deleted outright rather than hardened. The CLI now rejects the flag as unrecognized (`ArgumentParser.CommandError`), covered by `RollkeepCLIPathSchemeTests.testValidateRejectsRemovedSkipVerifyFlag` (`E2E-036`). The MVP invariant ("no file may skip staging or skip verification", spec section 11) is now enforced by the flag's absence rather than by degraded-but-honest reporting. Re-verify this scenario on every release in case the flag is ever reintroduced.

### `RT-P0-11` Writes must be destination-constrained
- Fixtures: `Tests/TestingDirs/SD_CARD1`, `Tests/TestingDirs/SD_CARD2`
- Mutation: none
- Run:
  - capture filesystem diff before and after ingest
  - compare created and modified paths
- Pass:
  - writes occur only under destination staging, destination receipts, final library directories/files, and optional local temp receipt fallback
  - source tree is untouched
- Fail / user harm:
  - privacy leak
  - collateral writes outside user intent
  - source mutation hidden behind a "successful" ingest

### `RT-P1-01` Same-name different-bytes collision must rename, never overwrite
- Fixture: temp clone of `Tests/TestingDirs/SD_CARD2`
- Mutation:
  - ingest once to a temp destination
  - modify one source file clone so it keeps the same filename but different bytes
  - ingest the modified clone into the same destination
- Pass:
  - second file lands as `name-1.ext` or next deterministic suffix
  - original final file remains unchanged
  - receipt records `CONFLICT_RENAMED`
- Fail / user harm:
  - library overwrite
  - user loses the first imported version without noticing

### `RT-P1-02` Unreadable source file must be explicit, isolated, and accounted for
- Fixture: temp clone of `Tests/TestingDirs/SD_CARD1`
- Mutation: make one media file unreadable
- Pass:
  - unreadable file is recorded as an `ERROR`
  - other readable files are still scanned and handled deterministically
  - final summary counts match reality; there is no silent omission
- Fail / user harm:
  - missing media hidden behind a mostly successful run
- Automated 2026-07-13: `scripts/e2e-unreadable-source-test.sh` (`E2E-035` in
  `Tests/e2e-ingest-matrix.md`) plus unit test
  `SourceScannerTests.testScanRecordsUnreadableFileAsErrorAndStillScansOtherFiles`.
  Confirmed the existing `SourceScanner` per-file `isReadable` check already
  handled this correctly (non-fatal `ScanErrorRecord`, scan continues); it
  simply had no automated coverage until now.

### `RT-P1-03` Missing or bad capture time must go to `_unsorted`, not to a guessed date bucket
- Fixture: temp clone of `Tests/TestingDirs/SD_CARD2`
- Mutation: strip or corrupt capture metadata on one photo and one video
- Pass:
  - file lands in `_unsorted/<CameraLabel>/<Photos|Videos>/`
  - receipt marks the fallback source
  - no invented date bucket is used
- Fail / user harm:
  - files disappear into the wrong month/year and are effectively lost to the user

### `RT-P1-05` Case and Unicode normalization collisions must not overwrite on macOS filesystems
- Fixture: temp clone of `Tests/TestingDirs/SD_CARD2`
- Mutation: add files whose names differ only by case or Unicode normalization
- Pass:
  - planner or commit logic resolves safely
  - no overwrite occurs on case-insensitive filesystems
  - receipt shows the chosen final path
- Fail / user harm:
  - one source file disappears during ingest on common macOS setups

### `RT-P1-06` Crash between verify and commit must be recoverable and auditable
- Preferred fixture: `Tests/TestingDirs/SD_CARD2`
- Mutation: kill the process after at least one staged file verifies and before commit finishes
- Pass:
  - receipt shows the last completed phase and touched paths
  - staging is retained
  - rerun does not overwrite or hide prior partial state
- Fail / user harm:
  - ambiguous recovery path
  - user cannot know whether to trust staging, final files, or neither

### `RT-P1-07` Symbolic links must be skipped and reported, never followed or fatal
- Fixture: `Tests/TestingDirs/SD_CARD1` clone with planted symlinks
- Mutation: add a file symlink and a directory symlink inside the source, both pointing to targets outside the source root
- Run: `scripts/e2e-symlink-skip-test.sh`
- Pass:
  - import completes `VERIFIED` with `errors = 0` (one stray symlink does not abort the whole card)
  - symlinks are not counted as candidates and are not committed
  - out-of-bound targets never appear in the library (source-boundary escape prevented)
  - source card is unchanged (symlinks remain, targets not copied in)
  - receipt records a `SCAN_WARNING` (`symbolic_link_skipped`) for each skipped link
- Fail / user harm:
  - a single alias on an existing HDD makes the entire import fail (recoverability/DoS)
  - or, worse, a link is followed and private out-of-scope files are imported
- Observed 2026-07-12: pass; scanner changed from hard-abort to skip-and-warn

### `RT-P1-08` Duplicate detection is destination-path-scoped, not library-wide
- Fixture: `Tests/TestingDirs/SD_CARD1`
- Mutation: pre-seed the destination with a byte-identical copy of one `SD_CARD1` file, placed at a path rollkeep's own path scheme would **not** compute (e.g. a manually organized folder, or a path produced under a different path-scheme setting)
- Run: ingest `SD_CARD1` into that destination
- Pass (documents current, accepted behavior — this is a known scope limit, not a bug, but it must stay visible):
  - rollkeep only compares content hashes against the exact path it would itself write to; it has no reverse hash index of the destination tree
  - the pre-seeded duplicate is not detected: the file is copied again into rollkeep's computed path and counted as newly committed
  - receipt and summary must not claim the file was recognized as a duplicate
- Fail / user harm:
  - if this silent re-copy behavior is ever *described* to the user as full duplicate protection (in UI copy, docs, or receipt language), that is a truthfulness violation — the honest claim today is only "this path was empty, I wrote here"
  - future risk: if a broader dedup pass is ever added without updating this test, a silent regression (e.g. accidentally skipping legitimately-different files with colliding partial hashes) could go unnoticed
- Verified 2026-07-13 (code audit): `DestinationPathPlanner.plan()`'s `existingFinalFiles` map is keyed by exact normalized path, and its only call site (`IngestPipelinePhases.swift`) never populates it, so plan-time dedup only covers duplicates within the same source batch. Commit-time dedup (`StagingCommitEngine.resolveCommitPath`) likewise only checks rollkeep's own computed final path and its numbered collision suffixes. No automated E2E coverage yet (`E2E-037`).

### `RT-P1-09` Concurrent runs against the same destination must not corrupt state or silently duplicate work
- Fixtures: `Tests/TestingDirs/SD_CARD1`, `Tests/TestingDirs/SD_CARD2`
- Mutation: launch two `rollkeep` processes at (near-)the same time against the same destination directory (same source card, or two different cards)
- Pass:
  - neither run's staging or receipt is corrupted or partially overwritten by the other (each session uses a UUID-scoped staging directory and receipt file)
  - final-path commit races resolve via collision-suffix retry, never via overwrite
  - minimum acceptable: no data corruption or overwrite
  - preferred: the app/CLI detects an in-flight run against the same destination and blocks or warns the second launch, rather than silently doing the work twice
- Fail / user harm:
  - two disconnected receipts exist for what the user believes was one ingest, making the audit trail confusing
  - two processes can each independently pass the disk-space preflight check and then jointly overrun the destination volume, causing an avoidable mid-copy failure
- Verified 2026-07-13 (code audit): no lock file, PID file, `flock`, `NSFileCoordinator`, or `O_EXCL` mutex exists anywhere in the source. Per-session UUID isolation prevents staging/receipt corruption, and `StagingCommitEngine.moveStagingToFinal` catches `EEXIST` on a concurrent winner's rename and retries with an incremented suffix, so data integrity holds — but there is no guard against accidental double-launch or the joint disk-space race described above. No automated E2E coverage yet (`E2E-038`).

### `RT-P2-01` Dry-run must never look equivalent to a verified ingest
- Fixtures: `Tests/TestingDirs/SD_CARD1`, `Tests/TestingDirs/SD_CARD2`
- Run: add `--dry-run --json`
- Pass:
  - status is clearly not `VERIFIED`
  - no staging or final files are created
  - receipt and summary make it obvious that only scan + plan were performed
- Fail / user harm:
  - user mistakes planning output for a safe offload

### `RT-P2-02` Auto-selection under ambiguity must force clarity, not guess
- Fixtures: mounted copies of `SD_CARD1` and `SD_CARD2`
- Mutation: present two likely cards and one remembered destination
- Pass:
  - source is not guessed silently when multiple likely cards exist
  - destination reuse is explicit and reversible
  - picker or error flow makes the ambiguity obvious
- Fail / user harm:
  - user ingests the wrong card to the wrong place

### `RT-P2-03` Unsupported companion files must be visibly excluded, not silently forgotten
- Fixture: temp clone of `Tests/TestingDirs/SD_CARD2`
- Mutation: add sidecars such as `.XMP`, `.AAE`, `.LRV`, or vendor metadata files
- Pass:
  - product behavior is explicit: either ignored-by-policy and counted, or supported
  - user can tell which files were intentionally excluded
- Fail / user harm:
  - user assumes "entire card" ingest when only media payloads were copied

## Minimal Harness Notes

### Fresh destination
Use a new temp destination for baseline runs:

```bash
DEST=$(mktemp -d /tmp/rollkeep-redteam.XXXXXX)
.build/debug/rollkeep --source Tests/TestingDirs/SD_CARD1 --dest "$DEST" --json
```

### Fixture clone for destructive red-team mutations
Never mutate the repo fixtures directly. Clone them first:

```bash
WORK=$(mktemp -d /tmp/rollkeep-redteam-fixture.XXXXXX)
cp -R Tests/TestingDirs/SD_CARD2/. "$WORK"
```

## Recommended Execution Order
Run these first on every release candidate:

1. `RT-P0-01`
2. `RT-P0-02`
3. `RT-P0-03`
4. `RT-P0-04`
5. `RT-P0-05`
6. `RT-P0-07`
7. `RT-P0-08`
8. `RT-P0-09`
9. `RT-P0-10`
10. `RT-P1-01`

Those ten tests cover the main ways a user can be harmed:

- source mutation
- overwrite or hidden duplicate behavior
- false-success signaling
- ambiguous recovery after failure

## Spec Anchors
- Invariants: sections 3 and 7
- Verification: sections 8 and 11
- Failure behavior: section 9
- Receipt guarantees: section 10
