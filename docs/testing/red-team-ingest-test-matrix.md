# Red Team Ingest Test Matrix

Status: working test plan + current spot-check results
Last updated: 2026-07-16
Scope: CLI ingest safety, truthfulness, and user-harm prevention

Note on the 2026-07-16 update: `RT-P0-12`, `RT-P1-10`, and `RT-P2-04` cover a
new category this matrix hadn't tested before -- adversarial/malformed
*content* inside embedded metadata and filenames, crafted to break the
hand-rolled parsers, as opposed to the real-world fault conditions (disk
full, disconnects, symlinks, crashes) the rest of this matrix targets.
`RT-P0-12` and `RT-P1-10` were fixed the same day (see each entry's "Fixed"
note for detail); `RT-P2-04` surfaced only a minor display-only finding and
was left as-is. The already-known, still-open items from the 2026-03-11 ISO
audit (sensitive identifiers in receipts, launcher UserDefaults retention)
and `RT-P1-08`/`RT-P1-09` below were intentionally not re-investigated in
this pass.

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
- Fixture profile: 11 candidates (6 photos, 4 videos, 1 standalone audio), ~318 MB
- Observed on 2026-07-16 (audio support added): baseline ingest `VERIFIED`, `copied = verified = committed = 11`, `errors = 0`
- Rerun result on same destination: `idempotent_rerun`, `committed = 0`, `duplicate_not_copied = 11`
- Includes a PNG screenshot without camera EXIF (`unknown-camera` label)
- Includes a standalone `.m4a` voice recording (no camera/device metadata by design) committed to the flat `<chronological>/audio/<filename>` bucket, labeled `audio`

### `Tests/TestingDirs/SD_CARD2` (mixed multi-camera card)
- Fixture profile: 29 candidates (19 photos, 10 videos, 0 standalone audio) + 3 transferable
  sidecars (Sony `M01.XML`, DJI `.SRT`, DJI Pocket 3 `.WAV`); ~1.5 GB
- Observed on 2026-07-16 (audio support added): baseline ingest `VERIFIED`, `copied = verified = committed = 32`, `errors = 0`
- Rerun result on same destination: `idempotent_rerun`, `committed = 0`, `duplicate_not_copied = 32` (sidecars are counted as duplicates too)
- Additional observed behavior: 12 distinct camera labels including
  `unknown-camera`; several MP4s without top-level Make/Model resolve labels
  via embedded metadata or fall back to `mtime_fallback`/`unknown-camera`
- The DJI Pocket 3 `.WAV` (DJI's uncompressed "high quality audio" companion track) is now a video sidecar rather than a skipped file — it commits next to its `.MP4` in `Videos/` and is not a standalone audio candidate

### Current Spot-Check Findings
- Resolved on 2026-03-10: `source == dest` is rejected at preflight with exit code `1`, and the temp source clone remained free of ingest artifacts.
- Resolved on 2026-03-10: destination nested inside source is rejected at preflight with exit code `1`, and no ingest folders were created inside the source tree.
- Resolved on 2026-07-12 (fixture rebuild): the `SD_CARD2` fixture-drift note previously here (`16`/`13`/`3` candidates) is obsolete. `SD_CARD2` now scans consistently as 27 candidates (17 photos, 10 videos) + 2 sidecars, matching the `Fixture Baseline` section above and confirmed against the committed `fixture-manifest.json` on 2026-07-13. Neither the old `16`/`13`/`3` nor the older `21`/`17`/`4` baseline should be used for release sign-off.
- Resolved on 2026-07-16: GoPro `.GPR` (a DNG-based RAW photo format) is no longer treated as an intentionally-unsupported companion — see the 2026-07-16 entry in `Tests/e2e-ingest-matrix.md`'s changelog. `SD_CARD2`'s baseline moved from 27 candidates (17 photos, 10 videos) to 29 candidates (19 photos, 10 videos); `copied = verified = committed` moved from 29 to 31; idempotent-rerun `duplicate_not_copied` moved from 29 to 31. Confirmed via a real CLI run against the committed `SD_CARD2` fixture: `VERIFIED`, `candidates=29 (photos=19, videos=10)`, `committed=verified=copied=31`, `errors=0`; rerun gives `idempotent_rerun`, `duplicate_not_copied=31`. The 2026-07-12 baseline above is superseded and should not be used for release sign-off.
- Resolved on 2026-03-21 (commit `807d468`): the `--skip-verify` command-surface spec gap is closed. The flag was deleted from the CLI entirely rather than hardened; supplying it now fails argument parsing before any ingest work starts. See the rewritten `RT-P0-10` below.
- Resolved on 2026-07-16: added audio ingestion — see the 2026-07-16 "added audio ingestion" entry in `Tests/e2e-ingest-matrix.md`'s changelog and `E2E-043`/`E2E-044` for full detail. `SD_CARD1`'s baseline moved from 10 candidates (6 photos, 4 videos) to 11 (6 photos, 4 videos, 1 standalone audio); `copied = verified = committed` moved from 10 to 11. `SD_CARD2`'s candidate count is unchanged at 29 (19 photos, 10 videos, 0 audio — the Pocket 3 `.WAV` is deliberately excluded from the candidate count as a video sidecar, not a standalone item), but `copied = verified = committed` moved from 31 to 32 (a third sidecar). Confirmed via real CLI runs against the committed fixtures: `SD_CARD1` `VERIFIED`, `candidates=11 (photos=6, videos=4, audio=1)`, `committed=verified=copied=11`, `errors=0`, `.m4a` lands at `<chronological>/audio/iphone recording.m4a`; `SD_CARD2` `VERIFIED`, `candidates=29 (photos=19, videos=10, audio=0)`, `committed=verified=copied=32`, `errors=0`, `.WAV` lands next to its `.MP4` in `Videos/`. The 2026-07-16 (GPR) baseline above is superseded and should not be used for release sign-off.

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
  - `candidates = 11`, `photos = 6`, `videos = 4`, `audio = 1`
  - `copied = 11`, `verified = 11`, `committed = 11`, `errors = 0`
  - receipt exists under `<DEST>/_ingest_receipts`
  - session staging directory is removed after success
  - the standalone `.m4a` recording commits to `<chronological>/audio/<filename>` (no camera-label folder, no `Photos`/`Videos` subfolder)
- Fail / user harm:
  - misleading camera inventory before card format
  - silent missing file or partial copy
- Observed 2026-07-16: pass (audio support added; counts updated from 10/6/4 to 11/6/4/1)

### `RT-P0-02` Baseline verified ingest on `SD_CARD2`
- Fixture: `Tests/TestingDirs/SD_CARD2`
- Destination: fresh temp directory
- Run: `.build/debug/rollkeep --source <SD_CARD2> --dest <DEST> --json`
- Pass:
  - exit code `0`
  - `status_label == VERIFIED`
  - `candidates = 29`, `photos = 19`, `videos = 10`, `audio = 0`
  - `copied = 32`, `verified = 32`, `committed = 32`, `errors = 0` (includes 3 transferable sidecars: Sony `M01.XML`, DJI `.SRT`, DJI Pocket 3 `.WAV`)
  - receipt exists under `<DEST>/_ingest_receipts`
  - fallback metadata events are recorded for videos using `mtime_fallback`
  - the Pocket 3 `.WAV` commits next to its `.MP4` in `Videos/`, not as a standalone audio candidate
- Fail / user harm:
  - user believes mixed media card is fully protected when it is not
  - video placement may become silently wrong if fallback is not disclosed
- Observed 2026-07-16: pass (audio support added; counts updated from 29/19/10/31 to 29/19/10/0-audio/32)

### `RT-P0-03` Idempotent rerun must never overwrite or duplicate-library-copy
- Fixtures: `Tests/TestingDirs/SD_CARD1`, `Tests/TestingDirs/SD_CARD2`
- Destination: reuse the successful destination from `RT-P0-01` or `RT-P0-02`
- Run: repeat the same ingest command against the same destination
- Pass:
  - exit code `0`
  - `idempotency.classification == idempotent_rerun`
  - `committed = 0`
  - `duplicate_not_copied = 11` for `SD_CARD1`
  - `duplicate_not_copied = 32` for `SD_CARD2`
  - no final file contents change
  - no `-1`, `-2`, ... conflict files are created for true duplicates
- Fail / user harm:
  - library bloat
  - accidental overwrite or hidden duplicate proliferation
- Observed 2026-07-16: pass on both cards (audio support added; counts updated from 10/31 to 11/32)

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

### `RT-P0-12` Malformed ISO-BMFF extended box size must not crash the process
Status: **FIXED 2026-07-16**
- Fixture: a minimal crafted blob, not a real MP4 -- one valid 8-byte box
  (`size=8, type="free"`) so `offset > 0` when the next box is reached,
  followed by a box with `size=1` ("use 64-bit extended size"), any type
  (e.g. `"moov"`), and an 8-byte big-endian extended size of `UInt64.max`.
  24 bytes total, saved with a `.mp4` extension.
- Mutation: place the crafted file (`crash.mp4`) alongside normal media in a
  cloned `SD_CARD1`, so a full-card run is exercised, not just an isolated
  file.
- Run:
  - Unit level: `Tests/rollkeepTests/ISOBMFFBoxWalkerTests.swift`'s
    `testGracefullyStopsOnExtendedSizeOverflow` (runs unconditionally as
    part of the normal suite -- no longer needs a crash-gating env var, now
    that the walker doesn't crash).
  - E2E level: `scripts/e2e-boxwalker-overflow-crash-test.sh` runs the real
    CLI binary against a cloned source card containing the crafted file and
    asserts a clean exit (`VERIFIED`, 0 errors, `crash.mp4` included as an
    ordinary candidate), following the same subprocess/returncode idiom as
    `scripts/e2e-crash-restart-recovery.py`.
- Pass:
  - the box walker returns gracefully (empty/partial box list) or the file
    is recorded as a per-file scan `ERROR`, matching the isolation bar set
    by `RT-P1-02`
  - no process-level crash (no signal-terminated exit) at any reachable
    call site
  - if scan cannot avoid a hard failure, it must be a catchable, explicit
    phase failure with a controlled non-zero exit code, not a signal death
- Fail / user harm:
  - a single crafted file crashes the whole process instead of being
    isolated as one file's scan error; unlike every other documented
    failure mode in this matrix, a signal-killed process gives no
    controlled exit code and no guaranteed final receipt event
  - reachable via the macOS Launcher's live card-preview scan
    (`Sources/rollkeepLauncher/LauncherViewModelActions.swift:240`,
    `mode: .preview`) with **no ingest action at all** -- just having the
    file on a mounted/browsed volume, before any `IngestSession`/receipt
    exists
- Severity note: read literally, the Priority Legend maps a signal-killed
  crash to P1 (no files are lost, and a crash is loud, not misleading).
  Classified as P0 here because it breaks a meta-property every other
  entry in this matrix relies on -- every documented failure elsewhere is a
  controlled, catchable, explicit-exit-code failure, never a raw trap --
  and because the Launcher preview-scan path needs zero user action.
  Renumber to `RT-P1-1x` if you'd rather reserve P0 strictly for data loss.
- Observed 2026-07-16 (pre-fix):
  - Unit level: confirmed crash. `swift test` output: `Process ... exited
    with unexpected signal code 5` (SIGTRAP -- Swift's checked-arithmetic
    overflow trap, exactly at the `offset + boxSize` addition in
    `Sources/RollKeepCore/ISOBMFFBoxWalker.swift:51`).
  - E2E/CLI level: confirmed via `scripts/e2e-boxwalker-overflow-crash-test.sh`
    against the real debug binary -- `rollkeep CLI was killed by signal 5
    while scanning crash.mp4`. Source fixture confirmed byte-for-byte
    unchanged after the crash (manifest hash comparison); destination had
    no partial writes (crash occurs during scan, before staging begins).
  - Launcher preview-scan reachability confirmed by code reading only (not
    GUI-automated in this pass): `scan(mode: .preview)` calls the same
    `ISOBMFFBoxWalker` path with no receipt/session in play.
- Fixed 2026-07-16: `ISOBMFFBoxWalker.readBoxes`'s `offset + boxSize` check
  (`Sources/RollKeepCore/ISOBMFFBoxWalker.swift:51`) now uses
  `offset.addingReportingOverflow(boxSize)` and treats an overflow the same
  as any other malformed/oversized box -- stop parsing this level instead of
  guessing, matching the existing philosophy already used for truncated and
  bogus-oversized boxes. Re-verified both ways:
  - Unit level: `testGracefullyStopsOnExtendedSizeOverflow` now passes
    unconditionally (no crash, walker returns `[ISOBMFFBox(type: "free", ...)]`
    and stops before the malformed box).
  - E2E/CLI level: `scripts/e2e-boxwalker-overflow-crash-test.sh` now
    confirms a clean `VERIFIED` exit with `crash.mp4` committed
    byte-identically as an ordinary (metadata-less, `unknown-camera`,
    `mtime_fallback`) video candidate -- no crash, no dropped file, no
    special-cased error path needed.
- Rule for binary parsers: Swift traps on integer overflow in `+`, `-`, and `*`.
  Use `addingReportingOverflow`, `multipliedReportingOverflow`, or explicit
  upper-bound clamps on any size, offset, or count read from untrusted bytes.

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
- Automated, real E2E (verified 2026-07-14 code audit): `scripts/existing-hdd-e2e-test.sh` → `scripts/existing-hdd-e2e.py` runs the real CLI binary against a real destination tree pre-seeded with same-name-different-bytes conflict files at rollkeep's own computed final path (`prepare_destination()`, scenarios `sd1-conflict-preseeded`/`sd2-conflict-preseeded` and the combined `mixed`/`full-duplicate`/`mixed-rerun` scenarios, feeding `E2E-025`–`E2E-032`). Asserts the pre-existing file is byte-unchanged, the new file lands at a deterministic `-1` suffix with the correct hash, and the receipt records `CONFLICT_RENAMED` — this is the actual described two-ingest scenario, not an approximation of it.
- Also covered at unit level: `resolveCommitPath` in `Sources/RollKeepEngine/StagingCommitEngine.swift:265` has no notion of "session" — it decides purely from what's on disk at commit time — so `StagingCommitEngineTests.testCommitAddsDeterministicSuffixWhenFinalPathAlreadyExists` (differing bytes → `-1` suffix, original untouched) and `testCommitSkipsDuplicateWhenExistingFinalMatchesHash` (matching bytes → `duplicateNotCopied`) exercise the identical code path in isolation, giving a fast-feedback layer under the E2E coverage above.

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
- Automated, case-only collisions (verified 2026-07-14 code audit): `DestinationPathPlannerTests.testPlanResolvesCaseOnlyFilenameCollisionsDeterministically` (plan-level: `IMG_6481.jpg` vs `IMG_6481.JPG` in the same batch resolve to a deterministic `-1` suffix, not a silent merge) and `StagingCommitEngineTests.testCommitReusesExistingLowercaseMediaDirectory` (commit-level: reuses an existing lowercase media directory rather than creating a case-variant duplicate directory on a case-insensitive filesystem).
- Automated, Unicode-normalization collisions, real E2E on real disk images (verified + closed 2026-07-14): `pathLookupKey` in `Sources/RollKeepCore/DestinationPathPlanner.swift:335` only applies `.caseInsensitive` folding, not Unicode normalization folding — so in isolation this looked like an unverified, possibly-live gap. Investigated empirically rather than guessed: created real HFS+, exFAT, and APFS disk images (`hdiutil create`) and confirmed macOS normalizes filenames at the VFS layer for **all three** — writing `café.jpg` (NFC) and then reading/stat-ing via the NFD spelling (`cafe´.jpg`, decomposed) resolves to the identical file on every one of them. That means `StagingCommitEngine.resolveCommitPath`'s real `fileManager.fileExists(atPath:)` check (`Sources/RollKeepEngine/StagingCommitEngine.swift:276`) already sees NFC/NFD spellings of the same name as one file and runs the existing hash-compare/suffix logic correctly — **no code change was needed**, `pathLookupKey` does not need normalization folding. This is now locked in with a real end-to-end test using the actual CLI binary against real HFS+/exFAT/APFS volumes: `scripts/e2e-unicode-normalization-test.sh` (`E2E-039`). It commits an NFC-named file, then ingests the identical content under the NFD spelling (asserts `duplicate_not_copied`, no second file), then ingests different content under the NFD spelling (asserts `conflicts_renamed`, deterministic `-1` suffix, original untouched) — on all three filesystems.
- Incidental finding while building the above (unrelated to Unicode normalization, fixed same day): `DestinationSpaceChecker.check()` preferred `URL.volumeAvailableCapacityForImportantUsage` over the plain `volumeAvailableCapacity`. That "important usage" key is an APFS purgeable-space concept; on exFAT it returns `0` rather than `nil`, so **every ingest to an exFAT destination failed preflight with "insufficient free space," regardless of actual free space** — a real bug affecting a common external-drive format, not a theoretical one. Fixed in `Sources/RollKeepEngine/DestinationSpaceChecker.swift:28` to only trust the "important usage" value when it's actually informative (`> 0`), falling back to plain available capacity otherwise. Regression-locked by the same `e2e-unicode-normalization-test.sh` (its exFAT leg would fail preflight without the fix) and by the pre-existing `scripts/e2e-fault-injection-test.sh` (`E2E-016`, confirmed still correctly detects genuine disk-full conditions after the fix).

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
- Re-confirmed 2026-07-16 (code audit, no new fixture): the `378d4d4`
  hard-abort-to-skip-and-warn softening changed only "one symlink kills the
  whole scan" -> "skip and warn, keep scanning" -- it did not touch or
  regress the fail-closed no-follow/no-escape guarantee.
  `Sources/RollKeepCore/SourceScannerTraversal.swift:45-57` still skips a
  symlink entry before ever calling `resolvingSymlinksInPath()` on it (the
  target is never touched), and the independent defense-in-depth layer at
  `Sources/RollKeepEngine/StagingCopyEngine.swift:392-420`
  (`O_RDONLY | O_NOFOLLOW`, explicit `symlink_not_allowed` rejection, `fstat`
  regular-file check) is unchanged.

### `RT-P1-08` Duplicate detection is destination-path-scoped, not library-wide
- Fixture: `Tests/TestingDirs/SD_CARD1`
- Mutation: pre-seed the destination with a byte-identical copy of one `SD_CARD1` file, placed at a path rollkeep's own path scheme would **not** compute (e.g. a manually organized folder, or a path produced under a different path-scheme setting)
- Run: ingest `SD_CARD1` into that destination
- Pass (documents current, accepted behavior — **permanent design decision, not a gap to be closed**):
  - rollkeep only compares content hashes against the exact path it would itself write to for that file; it has no reverse hash index of the destination tree, and none will be added
  - the pre-seeded duplicate is not detected: the file is copied again into rollkeep's computed path and counted as newly committed
  - receipt and summary must not claim the file was recognized as a duplicate
- Why this is accepted rather than a gap: `DestinationPathPlanner.plan()` computes the final path as a pure function of `(captureDate, cameraLabel, mediaType, compressionBucket, filename, pathScheme)` — see `Sources/RollKeepCore/DestinationPathPlanner.swift`. So re-ingesting the *same physical file* under the *same path-scheme settings* always computes the identical destination path, and the existing exact-path hash check catches that case correctly by construction. A library-wide hash scan would only ever catch two narrower, accepted-as-out-of-scope cases, and isn't worth its O(destination size) I/O cost on every ingest:
  1. the path-scheme setting was changed between sessions (`LauncherPathSchemeSettingsStore.swift`) and the same card is re-ingested under the new settings, computing a different path than the first ingest
  2. a byte-identical file entered the destination tree via a non-rollkeep route (manual copy, another tool, a pre-rollkeep manually organized archive)
- Fail / user harm:
  - if this re-copy behavior is ever *described* to the user as full duplicate protection (in UI copy, docs, or receipt language), that is a truthfulness violation — the honest claim today is only "this path was empty, I wrote here"
- Verified 2026-07-13 (code audit): `DestinationPathPlanner.plan()`'s `existingFinalFiles` map is keyed by exact normalized path, and its only call site (`IngestPipelinePhases.swift`) never populates it, so plan-time dedup only covers duplicates within the same source batch. Commit-time dedup (`StagingCommitEngine.resolveCommitPath`) likewise only checks rollkeep's own computed final path and its numbered collision suffixes. No automated E2E coverage yet (`E2E-037`).
- Decision reaffirmed 2026-07-14: reasoning above confirmed correct; no library-wide dedup work will be scheduled.

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

### `RT-P1-10` Unbounded embedded-metadata string must not block a whole run or hang PDF rendering
Status: **FIXED 2026-07-16**
- Fixture: a raw-bytes file (no valid MP4 structure required --
  `EmbeddedVideoMetadataTextParser`'s regex captures, e.g.
  `Model\s*[:=]\s*([^\r\n<]+)`, have no max-length bound) containing
  `"Model:" + "A"*N`, saved as `hostile.mp4`, size kept under the 2MB
  `byteCount` search window. Two variants:
  - (a) extreme: N ~ 1,900,000, so the resulting camera-label path
    component exceeds macOS's ~255-byte-per-component `NAME_MAX`
  - (b) boundary: N ~ 200, under `NAME_MAX` but over the fix's 128-byte
    cap, so the resulting directory name was absurd but filesystem-legal
    pre-fix
- Mutation: place alongside 1-2 normal fixture files in a cloned source dir
- Run: `scripts/e2e-metadata-length-bomb-test.sh` runs
  `.build/debug/rollkeep --source <clone> --dest <DEST> --json --pdf` for
  both variants against the real CLI binary.
- Pass (current, post-fix):
  - both (a) and (b) complete `VERIFIED`, with **every** file on the card
    committed, including the crafted one -- no whole-run-abort
  - `hostile.mp4`'s oversized `Model:` field is rejected (not truncated) by
    `sanitize()`'s 128-byte cap, so it falls back to `unknown-camera` like
    any other unresolvable field
  - every path component created under the destination stays within the
    128-byte cap -- no absurd folder names, in either variant
  - PDF generation stays fast (comparable to a normal run with no crafted
    file), since the oversized string never reaches rendering at all
- Fail / user harm (the pre-fix risk this test now guards against):
  - one pathological embedded metadata field could abort ingestion of an
    entire card (all other files, however many, were blocked in that run)
    via `Sources/RollKeepEngine/StagingCopyEngine.swift:117-174`'s
    first-failure-cancels-all `OperationQueue` design, and the offending
    file was effectively unidentifiable by a normal user since its own
    derived label/name was the illegible oversized string
  - separately, PDF receipt generation could become slow enough to look
    hung on a single crafted or corrupt file, undermining trust in the
    receipt step itself
  - a second, filesystem-independent reachability route existed via the
    "Camera Distribution" summary line (`CameraLabeler.assessCard` ->
    `Sources/RollKeepCore/PDFReceiptReportBuilder.swift:199-201`'s
    `distribution` map), which never touches `NAME_MAX` and worked even
    under `--dry-run` -- also closed by the same fix, since it shares the
    same root cause
- Observed 2026-07-16 (pre-fix):
  - Variant (a): confirmed via `scripts/e2e-metadata-length-bomb-test.sh`
    against the real CLI -- exit code `5` (`copyFailed`, matching
    `RollkeepExitCode` in `Sources/rollkeep/FinalSummaryRenderer.swift`),
    `status=aborted/FAILED`, `committed=0` of 2 otherwise-good files on the
    card (whole-run-abort blast radius confirmed), PDF still produced
    (209,227 bytes) because `--pdf` export runs regardless of aborted
    status (`Sources/RollKeepEngine/IngestFinalization.swift:129-150`).
  - Variant (b): confirmed `VERIFIED`, PDF produced, and the longest single
    path component actually created under the destination was 200 chars
    (the absurd-but-legal folder genuinely exists on a real filesystem).
  - PDF rendering cost, measured directly (not assumed) via
    `Tests/RollKeepEngineTests/PDFReceiptRenderingSupportBenchmarkTests.swift`:
    `wrappedLines`/`hardWrap` scale **linearly**, not quadratically, as
    hypothesized then corrected -- ~0.01s at 1K chars, ~0.07s at 10K,
    ~0.69s at 100K, ~3.5s at 500K, ~7.0s at 1M (`hardWrap` resets its
    accumulator to one character on every wrap-width overflow, so it never
    re-measures the full string). The real cost is a large constant factor
    in `wrappedLines`' pre-`hardWrap` step: a space-free hostile string is
    exactly one "word," so `textWidth()` runs one
    `CTLineCreateWithAttributedString` over the entire unbroken string
    first. Full pipeline at the real ~1.9MB worst case (opt-in via
    `ROLLKEEP_REPRODUCE_METADATA_LENGTH_BOMB=1`, since this is too slow to
    run in every default `swift test`): **11.5s**, producing a 209KB PDF,
    no crash. Not an unbounded hang, but a real, user-visible multi-second
    delay per crafted file that could compound with multiple hostile files
    on one card.
- Fixed 2026-07-16: `EmbeddedVideoMetadataTextParser`'s shared `sanitize()`
  helper (`Sources/RollKeepCore/EmbeddedVideoMetadataTextParser.swift`,
  called by every extracted make/model/serial value including via
  `sanitizeSerial()`) now rejects any value over 128 UTF-8 bytes -- matching
  the existing `DJIXtraMetadataDecoder.maxModelCodeUnits = 128` precedent,
  comfortably above any real camera identifier (e.g. "Apple iPhone 15 Pro
  13mm" is ~24 chars). Rejected (not truncated) values fall back to nil,
  same as any other unresolvable field, ultimately landing on
  `unknown-camera` -- consistent with the existing rejection philosophy
  already used for implausible serial numbers (all-zero, `4294967295`).
  Fixed at this single convergence point rather than downstream (`CameraLabeler.slug()`,
  `DestinationPathPlanner.sanitizeCameraLabel`, or the PDF renderer) because
  it's the true point of origin for all three identifier types from this
  parser, and prevents the oversized value from ever being constructed in
  the first place -- both reachability routes (path-planning and the
  Camera-Distribution PDF line) are closed by one change. Re-verified both
  ways:
  - Unit level: two new tests in `Tests/rollkeepTests/EmbeddedVideoMetadataTextParserTests.swift` --
    `testEmbeddedParserRejectsOversizedLabeledModelField` (2,000,000-char
    field -> `cameraModel == nil`) and
    `testEmbeddedParserAcceptsModelFieldAtLengthCapBoundary` (exactly
    128 chars -> passes through unchanged, confirming the cap doesn't
    clip legitimate-length values).
  - E2E/CLI level: `scripts/e2e-metadata-length-bomb-test.sh` now confirms
    both variants complete `VERIFIED` with **every** file on the card
    committed (baseline candidate count + 1, no whole-run-abort), `hostile.mp4`
    falls back to `unknown-camera`, every path component under the
    destination stays within the 128-byte cap, and PDF generation is fast
    again (~34KB, matching the size of a normal run, vs. 209KB pre-fix).

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

### `RT-P2-04` Hostile source filenames must be handled safely and legibly
- Fixture: `scripts/e2e-hostile-filenames-test.sh` creates a real HFS+ disk
  image (via `hdiutil`, reusing the pattern from
  `scripts/e2e-unicode-normalization-test.sh`) containing three hostile
  names in one `DCIM` folder: (a) a 254-character filename (250 `L`s +
  `.jpg`, near the ~255-byte-per-component `NAME_MAX`), (b) a filename
  whose true trailing extension is really `.mp4` but with a U+202E
  (RIGHT-TO-LEFT OVERRIDE) character embedded earlier, visually suggesting
  a different extension, (c) a filename containing raw ANSI escape-sequence
  bytes (`\x1b[2J`, `\x1b[31m`, `\x1b[0m`).
  Uses HFS+ rather than exFAT (the more realistic SD-card format): this
  environment's exFAT/FAT-family `hdiutil` driver failed "Operation not
  permitted" persistently (5+ retries with backoff), a localized
  environment/driver issue unrelated to rollkeep, while HFS+ creation
  succeeded reliably. The code paths under test (extension-based
  classification, scan counting, output escaping) are filesystem-agnostic,
  so this substitution doesn't weaken what's verified -- re-run on
  exFAT/APFS if a filesystem-specific difference is ever suspected.
- Mutation: none beyond the three hostile filenames above
- Run: `--json --dry-run` and plain (human-mode) `--dry-run` against the
  crafted source
- Pass:
  - all three are scanned deterministically as candidates, never silently
    dropped
  - the RTL-override file is classified by its TRUE trailing extension
    (video), not fooled by the visual spoofing
  - JSON output never contains a literal unescaped control byte
  - no terminal output corruption/injection when the CLI prints filenames
    in human (non-`--json`) mode
- Fail / user harm:
  - a spoofed or control-character filename misleads the user about what
    was actually imported, or corrupts/obscures terminal error output
  - reclassify to P1 if a max-length filename is ever found to trigger the
    same whole-run-abort blast radius documented in `RT-P1-10`, since
    `Sources/RollKeepCore/DestinationPathPlanner.swift:253-256` copies the
    source leaf name into the final path unsanitized and uncapped
- Observed 2026-07-16:
  - Max-length filename: scanned correctly, no silent drop (`candidates=3`).
  - RTL-override filename: correctly classified as a video by its true
    `.mp4` extension (`videos=1`) -- classification is a mechanical
    extension-suffix check, unaffected by embedded bidi characters earlier
    in the name. However, the raw U+202E override character **does** reach
    human-mode (non-JSON) terminal output unescaped, confirmed directly --
    a filename can visually spoof its real extension in any plain-text
    review context (terminal, and presumably receipts/PDF, not separately
    checked here).
  - Control-character filename: JSON output correctly contains no literal
    unescaped control byte (standard JSON string escaping). The raw ANSI
    escape-sequence bytes were **not** found literally in captured
    human-mode stdout in this test -- this specific terminal-injection
    hypothesis did not reproduce here (the default non-verbose summary may
    not print individual filenames at all, or a piped/captured stdout
    behaves differently than a real interactive TTY); reported honestly as
    not reproduced rather than forced into a finding.

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
10. `RT-P0-12`
11. `RT-P1-01`

Those eleven tests cover the main ways a user can be harmed:

- source mutation
- overwrite or hidden duplicate behavior
- false-success signaling
- ambiguous recovery after failure
- uncontrolled process crashes on adversarial file content

## Spec Anchors
- Invariants: sections 3 and 7
- Verification: sections 8 and 11
- Failure behavior: section 9
- Receipt guarantees: section 10
