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
| KI-7 | The app does not detect a card that the user inserts after it opens | `open` (potential bug) | 2026-10-05 |
| KI-8 | A failed or empty scan shows no reason, and the failed text is wrong | `open` (potential bug) | 2026-10-05 |
| KI-9 | The engine does not prevent idle sleep during an import | `open` | 2026-11-15 |
| KI-10 | Destination commit follows directory symbolic links outside the library root | `open` | 2026-11-15 |
| KI-11 | Overlap validator misses case differences and non-existing ancestor symlinks, and is not in the engine | `open` | 2026-11-15 |
| KI-12 | A collision suffix on a 254-byte or 255-byte filename exceeds the 255-byte limit and fails commit | `open` | 2026-11-15 |
| KI-13 | ExifDateParser drops capture date when timestamp falls into a DST spring-forward gap | `open` | 2026-11-15 |
| KI-2 | `VERIFIED` does not show files that were skipped | `deferred` | 2026-10-04 |
| KI-3 | A date failure after the move leaves an unrecorded library file | `deferred` | 2026-10-04 |
| KI-4 | The overlap check is not in the engine | `accepted` | 2026-10-04 |
| KI-1 | A long source filename aborts the whole run | `fixed` (one edge case remains open) | 2026-10-04 |

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
- **Code:** `Sources/RollKeepCore/SourceScanner.swift`, `Sources/RollKeepCore/CameraLabeler.swift`

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

### KI-7. The app does not detect a card that the user inserts after it opens

- **Status:** `open` (potential bug)
- **Found:** 2026-10-05 (while writing the user guide)
- **Spec / Invariants:** ROL-6 Section 2
- **Code:** `Sources/rollkeepLauncher/LauncherContentView.swift`, `LauncherViewModelActions.swift`
- **Related:** [docs/user-guide/README.md](../user-guide/README.md) (Section 3)

**Problem:**
The app looks for a card two times only:
1. When the window opens (`prepareDefaultsOnLaunch` in `LauncherContentView`).
2. When the user clicks "Import Another Card" (`importAnotherCard`).

Both call `applySuggestedSourceIfNeeded`. No code in `Sources/rollkeepLauncher` watches for a new mount.
A user who inserts the card after the app is open sees an empty Source row.
The user must click "Choose" and pick the card by hand.
The CLI does watch `/Volumes` when `--source` is omitted, so the two surfaces differ.
Spec Section 2 says "The app can detect a card". It does not say when.

**Options and next step:**
1. Keep launch-only detection and keep the note in the user guide.
2. Run `applySuggestedSourceIfNeeded` on a mount event while Source is empty and no run is active.

Owner must decide.
If fixed, update Section 3 of the user guide and run `scripts/release-app-smoke-test.sh --with-launcher-check` by hand (`AGENTS.md`).
Tracked in story [ST-10](stories.md#st-10-live-mount-detection-and-disk-image-dmg-filtering).

---

### KI-8. A failed or empty scan shows no reason, and the failed text is wrong

- **Status:** `open` (potential bug)
- **Found:** 2026-10-05 (while writing the user guide)
- **Spec / Invariants:** ROL-6 Section 2
- **Code:** `Sources/rollkeepLauncher/LauncherSetupViews.swift` (`LauncherSourceInventoryPanel.inventoryPlaceholderText`), `LauncherViewModelActions.swift` (`scheduleSourceScanIfNeeded`), `LauncherViewModelPresentation.swift` (`isImportReady`)
- **Tests:** `Tests/rollkeepLauncherTests` (reads `isImportReady` only; no test covers these states)

**Problem:**
Two problems have one cause. `inventoryPlaceholderText` reads `setupScopeSummaryText` only while the scan runs.
The messages for the other scan states never show on screen:
1. A scan error that is not a `SourceScannerError` sets `.failed("Source scan failed. You can still start import.")`.
   The panel shows the generic text "Scan details appear here once RollKeep can inspect the selected source."
   The text also says that the import can start, but `isImportReady` needs `.ready`, so the Import button stays dimmed.
   The text and the button disagree.
2. A scan that finds no media gives `.ready` with an item count of 0.
   The text "No media found." never shows. The panel shows counts of 0.
   `isImportReady` is true, so the Import button is enabled for an empty source.
   Nobody has run an import of an empty source for this entry; this was found by reading the code.

**Next step:**
Show the scan state message in the panel for `.failed` and for an empty `.ready`.
Owner must decide one rule for the failed state: dim the button and change the text, or enable the button as the text says.

---

### KI-10. Destination commit follows directory symbolic links outside the library root

- **Status:** `open`
- **Found:** 2026-11-15 (during the PhotoDropMac comparison)
- **Spec / Invariants:** ROL-6 Section 3 (I-9: Writes go only to allowed places), Section 5 (Commit)
- **Code:** `Sources/RollKeepEngine/StagingCommitEngine.swift` (`commit(files:)`, `moveStagingToFinal`), `Sources/RollKeepEngine/StagingCopyEngine.swift` (`openValidatedSourceFileDescriptor`)

**Problem:**
RollKeep blocks symbolic links on the source card (`SourceScannerTraversal.swift`, `StagingCopyEngine.swift`).
RollKeep does not check intermediate directory components on the destination library.
If an existing destination library contains a symbolic link directory (for example `2026 -> /external/path`), `FileManager.createDirectory` and `FileManager.moveItem` follow the link.
Committed files are written outside the library root. This violates Invariant I-9 ("Writes go only to allowed places").
Also, `open()` on the source does not set `O_NONBLOCK`. If a source entry is a FIFO (named pipe), `open()` hangs before `fstat()` can check `S_IFREG`.

**Next step:**
1. In `StagingCommitEngine`, reject intermediate destination paths that are symbolic links, or use directory-descriptor relative operations (`openat` with `O_NOFOLLOW`).
2. In `StagingCopyEngine`, add `O_NONBLOCK` to `open()` flags for source files.

---

### KI-11. Overlap validator misses case differences and non-existing ancestor symlinks, and is not in the engine

- **Status:** `open` (reopens and supersedes the accepted decision in KI-4)
- **Found:** 2026-11-15 (during the PhotoDropMac comparison)
- **Spec / Invariants:** ROL-6 Section 11 (Overlap preflight), I-10
- **Code:** `Sources/RollKeepCore/DirectoryPathOverlapValidator.swift`, `Sources/RollKeepEngine/IngestSession.swift`
- **Related:** [KI-4](#ki-4-the-overlap-check-is-not-in-the-engine), [KI-10](#ki-10-destination-commit-follows-directory-symbolic-links-outside-the-library-root)

**Problem:**
1. `DirectoryPathOverlapValidator.swift` compares path components with case sensitivity (`sourceComponents == destinationComponents`). On standard macOS case-insensitive filesystems (APFS and HFS+), `/Volumes/CARD` and `/volumes/card` are evaluated as disjoint.
2. `resolvingSymlinksInPath()` is called on the whole path. If a destination path component does not exist yet (for example, a new folder selected in the picker), the call cannot resolve symbolic links in parent directories.
3. `IngestSession.run()` does not call the overlap validator. Only the CLI and the app UI call it before starting a run (KI-4). Direct engine callers can start an ingest with overlapping paths.

**Next step:**
1. Update `DirectoryPathOverlapValidator`: resolve symbolic links on the deepest existing ancestor directory, append remaining components, and compare paths case-insensitively when on case-insensitive filesystems.
2. Call `DirectoryPathOverlapValidator.analyze()` in `IngestSession.run()` before starting Phase 1.

---

### KI-12. A collision suffix on a 254-byte or 255-byte filename exceeds the 255-byte limit and fails commit

- **Status:** `open`
- **Found:** 2026-10-04 (during `KI-1`; promoted to bug on 2026-11-15 during the PhotoDropMac comparison)
- **Spec / Invariants:** I-2, ROL-6 Section 5.5 (Commit and conflicts)
- **Code:** `Sources/RollKeepCore/DestinationPathPlanner.swift` (`pathByAppendingCollisionSuffix`), `Sources/RollKeepEngine/StagingCommitEngine.swift` (`pathByAppendingCollisionSuffix`, `pathByRemovingCollisionSuffix`)
- **Related:** [KI-1](#ki-1-a-long-source-filename-aborts-the-whole-run)

**Problem:**
When a destination file with the same name and different bytes already exists, RollKeep appends `-1`, `-2`, and so on before the file extension.
Neither `DestinationPathPlanner` nor `StagingCommitEngine` trims the filename stem before adding the collision suffix.
A source filename of 254 or 255 UTF-8 bytes exceeds the 255-byte filesystem component limit after adding `-1`.
The commit fails for that file.

**Next step:**
1. Add a shared UTF-8 stem trim helper in `RollKeepCore`. Limit the final filename to 255 UTF-8 bytes on a `Character` boundary.
2. Call the helper in `DestinationPathPlanner.pathByAppendingCollisionSuffix` and `StagingCommitEngine.pathByAppendingCollisionSuffix`.
3. Keep the untruncated base filename in `StagingCommitEngine` during commit checks. Do not trim `-\(suffix)` with `pathByRemovingCollisionSuffix` on a trimmed stem.
4. Update ROL-6 Section 5.5 in the same commit if needed. Add unit tests for 254-byte and 255-byte ASCII and multi-byte UTF-8 collisions.

---

### KI-13. ExifDateParser drops capture date when timestamp falls into a DST spring-forward gap

- **Status:** `open`
- **Found:** 2026-11-15 (during the PhotoDropMac comparison)
- **Spec / Invariants:** ROL-6 Section 5.1 (Scan and inventory), I-4 (Embedded metadata preservation)
- **Code:** `Sources/RollKeepCore/ImageIOPhotoMetadataExtractor.swift` (`ExifDateParser.parse`, `formattersWithoutTimeZone`)

**Problem:**
`ExifDateParser` parses naive EXIF dates (`yyyy:MM:dd HH:mm:ss`) using `DateFormatter` configured with `timeZone: .current`.
In regions with Daylight Saving Time (DST), the clock skips forward by one hour in the spring (for example from 02:00:00 to 03:00:00).
If a camera clock records a time in that skipped hour (for example `02:30:00`), `DateFormatter.date(from:)` returns `nil`.
RollKeep then drops the valid EXIF date and falls back to the file modification time (`mtime`).
This can place the file into the wrong year or month folder, and the receipt marks the capture date as missing from EXIF.

**Next step:**
1. Replace `DateFormatter` for dates without time zones with component parsing and `Calendar.date(from: DateComponents)`.
2. Add validation to reject zero or out-of-range dates from dead camera batteries (`month` 1–12, `day` 1–31, `hour` 0–23).
3. Add unit tests in `RollKeepCoreTests` for the spring-forward DST gap and zero-padded empty timestamps (`0000:00:00 00:00:00`).

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
- **Code:** `Sources/RollKeepEngine/StagingCommitEngine.swift` (`commitSingle`)

**Problem:**
In `commitSingle`, `applySourceDates` runs after the file moves to its final path.
If setting the modification date fails, the commit counts as failed, but the file is already in the library.
That file is not in the list of committed files in the result.
The receipt records the failure with the attempted final path.
The library keeps the file, so I-2 and I-7 hold. The record of what is in the library is incomplete for that one file.

---

### KI-4. The overlap check is not in the engine

- **Status:** `accepted` (superseded by open bug [KI-11](#ki-11-overlap-validator-misses-case-differences-and-non-existing-ancestor-symlinks-and-is-not-in-the-engine))
- **Spec / Invariants:** ROL-6 Section 11 (Overlap preflight), I-10
- **Code:** `Sources/rollkeep/VolumeResolver.swift`, `Sources/rollkeepLauncher/LauncherPathValidationAndLocator.swift`

**Decision:**
The check that rejects overlapping source and destination folders is in the CLI and in the app. `IngestSession` does not call it.
The owner accepts this. Source and destination paths are fixed at run start (I-10), and both surfaces check them before the run.
Any new surface that starts an ingest must call the check (spec Section 11).

---

## Fixed bugs

### KI-9. The engine does not prevent idle sleep during an import

- **Status:** `fixed` (2026-11-15, story [ST-9](stories.md#completed-stories))
- **Spec / Invariants:** ROL-6 Section 2, Section 9
- **Code:** `Sources/RollKeepEngine/IdleSleepAssertion.swift`, `Sources/RollKeepEngine/IngestSession.swift` (`IngestSession.run()`)
- **Tests:** `Tests/RollKeepEngineTests/IdleSleepAssertionTests.swift`

**What was fixed:**
`IngestSession.run()` now acquires a `kIOPMAssertionTypePreventUserIdleSystemSleep` power assertion through `SystemIdleSleepAssertionManager` (`IOPMAssertionCreateWithName`).
A `defer` block releases the assertion when `run()` returns or throws.
If acquiring the assertion fails, the engine logs a warning and continues the ingest.

---

### KI-1. A long source filename aborts the whole run

- **Status:** `fixed` (2026-10-04) — **one related edge case remains open without an ID**
- **Spec / Invariants:** ROL-6 Section 5, I-7
- **Code:** `Sources/RollKeepEngine/StagingCopyEngine.swift` (`tempName`)
- **Tests:** `StagingCopyEngineTests` (covers 254-byte filename), `scripts/e2e-hostile-filenames-test.sh` (uses `--dry-run`)

**What was fixed:**
The copy step previously gave each file a hidden temporary name `.<filename>.rollkeep-<uuid>.tmp` (adding about 51 bytes).
A source filename of 205 bytes or more exceeded the 255-byte filesystem limit, failed with "Failed to create temporary staging file", and aborted the run in `copy`.
The hidden temp name is now `.rollkeep-<uuid>.tmp` (fixed length, no filename).
A test run with names of 154, 204, and 254 bytes commits all three files.

**Related items:**
- The Film Mode temporary name (`.<filename>.filmmode-tmp`) hits the 255-byte limit for names of 242 bytes or more. Its failure is not fatal: the file counts as "Film Mode EXIF skipped". (Open without ID.)
- A collision suffix on a name of 254 bytes or more can make the final name too long. Now tracked as open bug [KI-12](#ki-12-a-collision-suffix-on-a-254-byte-or-255-byte-filename-exceeds-the-255-byte-limit-and-fails-commit).

Assign an ID (`KI-14`) if the owner wants to track the Film Mode item separately.
