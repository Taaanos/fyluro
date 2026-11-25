# Bugs and Known Gaps

This file lists bugs and gaps that we know about.
The spec ([ROL-6-spec-and-invariants.md](../ROL-6-spec-and-invariants.md)) defines intended behavior.
This file describes where the code differs or fails.
None of these items breaks an invariant (`I-1` to `I-10`).

Status values: `open`, `in-progress`, `blocked`, `deferred`, `accepted`, `fixed`.

## Summary

| ID | Issue | Status | Found |
| --- | --- | --- | --- |
| KI-5 | Stop Import is slow during the scan | `open` | 2026-10-04 |
| KI-6 | One inventory row can cover files with different camera model codes | `open` | 2026-10-05 |
| KI-15 | Film Mode temp name exceeds 255 bytes on long filenames | `open` | 2026-10-04 |
| KI-7 | The app does not detect a card that the user inserts after it opens | `fixed` | 2026-10-05 |
| KI-8 | A failed or empty scan shows no reason, and the failed text is wrong | `fixed` | 2026-10-05 |
| KI-9 | The engine does not prevent idle sleep during an import | `fixed` | 2026-11-15 |
| KI-10 | Destination commit follows directory symbolic links outside the library root | `fixed` | 2026-11-15 |
| KI-11 | Overlap validator misses case differences and non-existing ancestor symlinks, and is not in the engine | `fixed` | 2026-11-15 |
| KI-12 | A collision suffix on a 254-byte or 255-byte filename exceeds the 255-byte limit and fails commit | `fixed` | 2026-11-15 |
| KI-13 | ExifDateParser drops capture date when timestamp falls into a DST spring-forward gap | `fixed` | 2026-11-15 |
| KI-14 | macOS App Nap throttles disk I/O and CPU during backgrounded imports | `fixed` | 2026-11-23 |
| KI-2 | `VERIFIED` does not show files that were skipped | `deferred` | 2026-10-04 |
| KI-3 | A date failure after the move leaves an unrecorded library file | `deferred` | 2026-10-04 |
| KI-4 | The overlap check is not in the engine | `fixed` (superseded by KI-11) | 2026-10-04 |
| KI-1 | A long source filename aborts the whole run | `fixed` | 2026-10-04 |

---

## Open bugs

### KI-5. Stop Import is slow during the scan

- **Status:** `open` (cause confirmed, fix not decided)
- **Found:** 2026-10-04 (reported by owner)
- **Spec / Invariants:** ROL-6 Section 9 (Cancel), I-1, I-6, I-7
- **Investigation:** [INV-1-stop-import-latency.md](../investigations/INV-1-stop-import-latency.md)

**Problem:**
A stop during the copy phase is instant.
A stop during the scan waits for the whole scan (17 s for 2259 files in one measured run).
The scanner does not read the cancel flag.
The receipt of that run proves it: the cancel error comes after a full `SCAN_SUMMARY`, with phase `plan`.
The code follows ROL-6 Section 9, so the delay is not a spec violation. It is a usability gap.

**Next step:**
Approve Option A in [INV-1-stop-import-latency.md](../investigations/INV-1-stop-import-latency.md) (check `shouldCancel` per file in `SourceScanner`).
Update ROL-6 Section 9 in the same commit to add `scan file` as a cancel boundary.

---

### KI-6. One inventory row can cover files with different camera model codes

- **Status:** `open`
- **Found:** 2026-10-05 (during UI-S5)
- **Spec / Invariants:** ROL-6 Section 6
- **Code:** `Sources/FyluroCore/SourceScanner.swift`, `Sources/FyluroCore/CameraLabeler.swift`

**Problem:**
The scan inventory counts files by folder name. Different model codes can give one folder name.
In the test card, `iPhone 15 Pro` (photos) and `Apple iPhone 15 Pro 13mm` (one video) both give `iphone-15-pro`.
The row keeps only the first model code it sees.
The camera catalog matches the exact model code (spec Section 6).
A name for one code does not apply to the files of the other code.
So the Settings list "On the Current Card" can show the unusual code and not the common one.
The user then cannot name the hidden code.
The import itself places each file by its own model code, so the library is correct.

**History and next step:**
An attempt to list every code was reverted on 2026-10-05 because it touched `CameraLabeler.swift`.
The owner did not want that risk and is thinking about removing the camera label feature.
Decide whether to fix the scan (count each model code first, then group) or remove camera labels.

---

### KI-15. Film Mode temp name exceeds 255 bytes on long filenames

- **Status:** `open`
- **Found:** 2026-10-04 (split from [KI-1](#ki-1-a-long-source-filename-aborts-the-whole-run))
- **Spec / Invariants:** ROL-6 Section 5, I-4

**Problem:**
The Film Mode temporary name (`.<filename>.filmmode-tmp`) hits the 255-byte filesystem limit for source names of 242 bytes or more.
The failure is not fatal: the file stays in the library without rewritten EXIF and counts as "Film Mode EXIF skipped".

**Next step:**
Use a fixed-length temporary name (such as `.fyluro-filmmode-<uuid>.tmp`) if long Film Mode filenames need EXIF writes.

---

## Deferred and accepted gaps

### KI-2. `VERIFIED` does not show files that were skipped

- **Status:** `deferred` (owner decision, 2026-10-04)
- **Spec / Invariants:** ROL-6 Section 8 (`VERIFIED` definition)
- **Related:** [story-3-import-states.md](../ui-overhaul/story-3-import-states.md) (decision 6), `scripts/e2e-unreadable-source-test.sh`

**Problem:**
A run ends `VERIFIED` when every file that reached the copy phase passed verification (spec Section 8).
Files that the scan skips or cannot read do not reach the copy phase.
These are unreadable files, symbolic links, and large files with an unknown extension.
The summary lists them as errors and warnings, and `scripts/e2e-unreadable-source-test.sh` requires this result.
The `VERIFIED` label alone does not show them. A user could format the card and believe that every file is copied.

**Decision:**
Options considered: keep as is; show "N files were not copied" next to the label; change the label when the error count is above 0.
Deferred. Revisit before the "Verified" label ships in the UI.

---

### KI-3. A date failure after the move leaves an unrecorded library file

- **Status:** `deferred` (owner decision, 2026-10-04)
- **Spec / Invariants:** I-2, I-7, I-8
- **Code:** `Sources/FyluroEngine/StagingCommitEngine.swift` (`commitSingle`)

**Problem:**
In `commitSingle`, `applySourceDates` runs after the file moves to its final path.
If setting the modification date fails, the commit counts as failed, but the file is already in the library.
That file is not in the list of committed files in the result.
The receipt records the failure with the attempted final path.
The library keeps the file, so I-2 and I-7 hold. The record of what is in the library is incomplete for that one file.

---

## Fixed bugs

### KI-4. The overlap check is not in the engine

- **Status:** `fixed` (2026-11-15, superseded by [KI-11](#ki-11-overlap-validator-misses-case-differences-and-non-existing-ancestor-symlinks-and-is-not-in-the-engine))
- **Spec / Invariants:** ROL-6 Section 11 (Overlap preflight), I-10

**What was fixed:**
`IngestSession.run()` now runs `DirectoryPathOverlapValidator.analyze()` before opening a receipt or creating any folder.

### KI-14. macOS App Nap throttles disk I/O and CPU during backgrounded imports

- **Status:** `fixed` (2026-11-23)
- **Spec / Invariants:** ROL-6 Section 2, Section 9
- **Code:** `Sources/FyluroEngine/IdleSleepAssertion.swift`
- **Tests:** `Tests/FyluroEngineTests/IdleSleepAssertionTests.swift`

**What was fixed:**
`SystemIdleSleepAssertionManager` previously acquired only `IOPMAssertionCreateWithName` (`kIOPMAssertionTypePreventUserIdleSystemSleep`), which prevented idle sleep (KI-9) but did not block macOS App Nap. When the user switched away from Fyluro during an import, `runningboardd` enabled App Nap with `disk:Y` and `cpu:Y`, throttling disk I/O. `SystemIdleSleepAssertionManager` now also starts a `.userInitiated` `ProcessInfo` activity (`ProcessInfo.processInfo.beginActivity`) for the run and ends it on release or `deinit`.

### KI-8. A failed or empty scan shows no reason, and the failed text is wrong

- **Status:** `fixed` (2026-11-15)
- **Spec / Invariants:** ROL-6 Section 2
- **Code:** `Sources/fyluroLauncher/LauncherSetupViews.swift`, `Sources/fyluroLauncher/LauncherViewModelActions.swift`, `Sources/fyluroLauncher/LauncherViewModelPresentation.swift`, `docs/user-guide/README.md`
- **Tests:** `Tests/fyluroLauncherTests/LauncherCoreViewModelBehaviorTests.swift`

**What was fixed:**
Added `setupInventoryPlaceholderText`, `isSourceScanFailed`, and `setupEmptySourceMessage` on `LauncherViewModel` and wired them into `LauncherSourceInventoryPanel`. Failed scans now display an error `NoticeBanner` with the failure message (and generic scan errors now say `"Source scan failed."` so the text matches the dimmed Import button). Empty scans (`.ready` with 0 items) now show `"No media found."` below the zeroed count grid.

### KI-7. The app does not detect a card that the user inserts after it opens

- **Status:** `fixed` (2026-11-15, story [ST-10](stories.md#completed-stories))
- **Spec / Invariants:** ROL-6 Section 2
- **Code:** `Sources/fyluroLauncher/LauncherVolumeDefaults.swift`, `Sources/fyluroLauncher/LauncherViewModel.swift`, `Sources/fyluroLauncher/LauncherViewModelActions.swift`, `docs/user-guide/README.md`
- **Tests:** `Tests/fyluroLauncherTests/LauncherCoreVolumeLocatorTests.swift`, `Tests/fyluroLauncherTests/LauncherCoreViewModelDefaultsActionsTests.swift`

**What was fixed:**
`LauncherViewModel` now observes `NSWorkspace.didMountNotification` and `NSWorkspace.didUnmountNotification`, clears `sourcePath` when the selected source volume unmounts on the setup screen, and calls `applySuggestedSourceIfNeeded()` when `sourcePath` is empty and no import is active. `LauncherVolumeInspector` now excludes mounted disk images (`.dmg`) via Disk Arbitration so installer disk images are not picked as camera cards.

### KI-13. ExifDateParser drops capture date when timestamp falls into a DST spring-forward gap

- **Status:** `fixed`
- **Fixed:** 2026-11-15
- **Spec / Invariants:** ROL-6 Section 5 (Timezone policy), I-4
- **Fix:** Replaced `DateFormatter` for naive EXIF dates in `Sources/FyluroCore/ImageIOPhotoMetadataExtractor.swift` (`ExifDateParser`) with strict `yyyy:MM:dd HH:mm:ss` component parsing, range checks (`year >= 1`, `month` 1–12, `day` 1–days in month, `hour` 0–23, `minute` 0–59, `second` 0–59), and `Calendar.date(from:)`. Added DST spring-forward gap and zero-date tests in `Tests/fyluroTests/ExifDateParserTests.swift`.

### KI-12. A collision suffix on a 254-byte or 255-byte filename exceeds the 255-byte limit and fails commit

- **Status:** `fixed`
- **Fixed:** 2026-11-15
- **Spec / Invariants:** I-2, ROL-6 Section 7
- **Fix:** Added `CollisionFilenameBuilder` in `Sources/FyluroCore/CollisionFilenameBuilder.swift` to trim filename stems on a `Character` boundary and keep collision filenames within 255 UTF-8 bytes. Updated `DestinationPathPlanner` and `StagingCommitEngine` to use the helper, and updated `StagingCommitEngine` to keep the untruncated source filename during commit checks and suffix retries. Added unit tests in `DestinationPathPlannerTests` and `StagingCommitEngineTests`.

### KI-11. Overlap validator misses case differences and non-existing ancestor symlinks, and is not in the engine

- **Status:** `fixed` (2026-11-15)
- **Spec / Invariants:** ROL-6 Section 11 (Overlap preflight), I-10
- **Code:** `Sources/FyluroCore/DirectoryPathOverlapValidator.swift`, `Sources/FyluroEngine/IngestSession.swift`, `Sources/fyluro/VolumeResolver.swift`
- **Tests:** `Tests/fyluroTests/DirectoryPathOverlapValidatorTests.swift`, `Tests/FyluroEngineTests/IngestSessionEventsTests.swift`

**What was fixed:**
`DirectoryPathOverlapValidator` now walks up to the deepest existing ancestor directory, resolves symbolic links there, appends any non-existing trailing components, and compares components case-insensitively when either ancestor sits on a case-insensitive volume. `IngestSession.run()` now runs `DirectoryPathOverlapValidator.analyze()` before opening a receipt or creating any folder, throwing `IngestPreflightError.overlappingPaths` when paths overlap.

---

### KI-10. Destination commit follows directory symbolic links outside the library root

- **Status:** `fixed` (2026-11-15)
- **Spec / Invariants:** ROL-6 Section 3 (I-9), Section 11
- **Code:** `Sources/FyluroEngine/StagingCommitEngine.swift`, `Sources/FyluroEngine/StagingCopyEngine.swift`, `Sources/FyluroEngine/IngestPipelinePhases.swift`
- **Tests:** `Tests/FyluroEngineTests/StagingCommitEngineTests.swift`, `Tests/FyluroEngineTests/StagingCopyEngineTests.swift`

**What was fixed:**
`StagingCommitEngine` now takes `destinationRoot`. It walks every path component inside `destinationRoot` with `openat(..., O_NOFOLLOW)` and creates directories with `mkdirat`. It rejects symbolic links and paths outside `destinationRoot`, hashes existing files via `openat(..., O_NOFOLLOW)`, and moves staged files via `renameatx_np` (with `RENAME_EXCL`) into the verified parent directory descriptor. `StagingCopyEngine` now opens source files with `O_NONBLOCK` so a source FIFO fails immediately instead of hanging.

---

### KI-9. The engine does not prevent idle sleep during an import

- **Status:** `fixed` (2026-11-15, story [ST-9](stories.md#completed-stories))
- **Spec / Invariants:** ROL-6 Section 2, Section 9
- **Code:** `Sources/FyluroEngine/IdleSleepAssertion.swift`, `Sources/FyluroEngine/IngestSession.swift` (`IngestSession.run()`)
- **Tests:** `Tests/FyluroEngineTests/IdleSleepAssertionTests.swift`

**What was fixed:**
`IngestSession.run()` now acquires a `kIOPMAssertionTypePreventUserIdleSystemSleep` power assertion through `SystemIdleSleepAssertionManager` (`IOPMAssertionCreateWithName`).
A `defer` block releases the assertion when `run()` returns or throws.
If acquiring the assertion fails, the engine logs a warning and continues the ingest.

---

### KI-1. A long source filename aborts the whole run

- **Status:** `fixed` (2026-10-04)
- **Spec / Invariants:** ROL-6 Section 5, I-7
- **Code:** `Sources/FyluroEngine/StagingCopyEngine.swift` (`tempName`)
- **Tests:** `StagingCopyEngineTests` (covers 254-byte filename), `scripts/e2e-hostile-filenames-test.sh` (uses `--dry-run`)

**What was fixed:**
The copy step previously gave each file a hidden temporary name `.<filename>.fyluro-<uuid>.tmp` (adding about 51 bytes).
A source filename of 205 bytes or more exceeded the 255-byte filesystem limit, failed with "Failed to create temporary staging file", and aborted the run in `copy`.
The hidden temp name is now `.fyluro-<uuid>.tmp` (fixed length, no filename).
A test run with names of 154, 204, and 254 bytes commits all three files.

**Related items:**
- The Film Mode temporary name (`.<filename>.filmmode-tmp`) hits the 255-byte limit for names of 242 bytes or more. Tracked in [KI-15](#ki-15-film-mode-temp-name-exceeds-255-bytes-on-long-filenames).
- A collision suffix on a name of 254 bytes or more can make the final name too long. Fixed in [KI-12](#ki-12-a-collision-suffix-on-a-254-byte-or-255-byte-filename-exceeds-the-255-byte-limit-and-fails-commit).
