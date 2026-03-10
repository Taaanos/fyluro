# Red Team Ingest Test Matrix

Status: working test plan + initial spot-check results
Last updated: 2026-03-10
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

### `Tests/TestingDirs/SD_CARD1`
- Fixture profile: 9 candidates
- Observed on 2026-03-10: 8 photos, 1 video
- Baseline ingest result: `VERIFIED`
- Rerun result on same destination: `idempotent_rerun`, `duplicate_not_copied = 9`

### `Tests/TestingDirs/SD_CARD2`
- Fixture profile: 21 candidates
- Observed on 2026-03-10: 17 photos, 4 videos
- Baseline ingest result: `VERIFIED`
- Rerun result on same destination: `idempotent_rerun`, `duplicate_not_copied = 21`
- Additional observed behavior: 3 video files fell back to `mtime_fallback`

### Current Spot-Check Findings
- Critical: `source == dest` is currently accepted. Running the CLI with the same path for source and destination created `2026/...` library folders and `_ingest_receipts` inside the source tree.
- Spec gap on command surface: `--skip-verify` is still exposed even though the MVP spec says no file may skip verification.
- Truthfulness concern: `SD_CARD2` produced six camera labels in `CAMERA_LABEL_DETECTED.labels`, but `mixed_camera_detected` was `false`.

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
  - `candidates = 9`, `photos = 8`, `videos = 1`
  - `copied = 9`, `verified = 9`, `committed = 9`, `errors = 0`
  - receipt exists under `<DEST>/_ingest_receipts`
  - session staging directory is removed after success
- Fail / user harm:
  - false confidence before card format
  - silent missing file or partial copy
- Observed 2026-03-10: pass

### `RT-P0-02` Baseline verified ingest on `SD_CARD2`
- Fixture: `Tests/TestingDirs/SD_CARD2`
- Destination: fresh temp directory
- Run: `.build/debug/rollkeep --source <SD_CARD2> --dest <DEST> --json`
- Pass:
  - exit code `0`
  - `status_label == VERIFIED`
  - `candidates = 21`, `photos = 17`, `videos = 4`
  - `copied = 21`, `verified = 21`, `committed = 21`, `errors = 0`
  - receipt exists under `<DEST>/_ingest_receipts`
  - fallback metadata events are recorded for videos using `mtime_fallback`
- Fail / user harm:
  - user believes mixed media card is fully protected when it is not
  - video placement may become silently wrong if fallback is not disclosed
- Observed 2026-03-10: pass

### `RT-P0-03` Idempotent rerun must never overwrite or duplicate-library-copy
- Fixtures: `Tests/TestingDirs/SD_CARD1`, `Tests/TestingDirs/SD_CARD2`
- Destination: reuse the successful destination from `RT-P0-01` or `RT-P0-02`
- Run: repeat the same ingest command against the same destination
- Pass:
  - exit code `0`
  - `idempotency.classification == idempotent_rerun`
  - `committed = 0`
  - `duplicate_not_copied = 9` for `SD_CARD1`
  - `duplicate_not_copied = 21` for `SD_CARD2`
  - no final file contents change
  - no `-1`, `-2`, ... conflict files are created for true duplicates
- Fail / user harm:
  - library bloat
  - accidental overwrite or hidden duplicate proliferation
- Observed 2026-03-10: pass

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
- Observed 2026-03-10: fail; current CLI exited `0` and wrote new catalog paths into the source tree

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

### `RT-P0-10` Verification bypass must not be sold as full safety
- Fixture: `Tests/TestingDirs/SD_CARD1`
- Run: `.build/debug/rollkeep --source <SD_CARD1> --dest <DEST> --skip-verify --json`
- Pass:
  - preferred MVP behavior: reject the flag because the spec forbids skipped verification
  - minimum acceptable temporary behavior: never print `VERIFIED`, clearly state verification was skipped, and mark the run as degraded in summary and receipt
- Fail / user harm:
  - user interprets a non-verified copy as safe to format
- Observed 2026-03-10:
  - current CLI did not print `VERIFIED`
  - current CLI returned `COMPLETED (verification skipped)`
  - the flag still conflicts with the MVP spec

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

### `RT-P1-03` Missing or bad capture time must go to `_unsorted`, not to a guessed date bucket
- Fixture: temp clone of `Tests/TestingDirs/SD_CARD2`
- Mutation: strip or corrupt capture metadata on one photo and one video
- Pass:
  - file lands in `_unsorted/<CameraLabel>/<Photos|Videos>/`
  - receipt marks the fallback source
  - no invented date bucket is used
- Fail / user harm:
  - files disappear into the wrong month/year and are effectively lost to the user

### `RT-P1-04` Mixed-camera truthfulness must not collapse into a misleading single-camera story
- Fixture: `Tests/TestingDirs/SD_CARD2`
- Mutation: none
- Pass:
  - `CAMERA_LABEL_DETECTED.labels` reflects all observed labels and counts
  - if materially mixed, UI and receipt make that obvious
  - user-facing summary does not imply "single-camera card" when evidence is mixed
- Fail / user harm:
  - user trusts the wrong library placement or wrong support conclusion
- Observed 2026-03-10:
  - receipt emitted six labels
  - `mixed_camera_detected` was `false`
  - this deserves investigation as a truthfulness risk

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
11. `RT-P1-04`

Those eleven tests cover the main ways a user can be harmed:

- source mutation
- overwrite or hidden duplicate behavior
- false-success signaling
- ambiguous recovery after failure
- misleading metadata or camera classification

## Spec Anchors
- Invariants: sections 3 and 7
- Verification: sections 8 and 11
- Failure behavior: section 9
- Receipt guarantees: section 10
