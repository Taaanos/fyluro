# ROL-6: Product Spec and Invariants

Status: Production baseline for implementation
Owner: Product
Scope: App-first ingest system (macOS app primary surface; CLI shared engine/complementary interface)
Last updated: 2026-10-05

## 1) Purpose
Define non-negotiable behavior for ingesting media from a source card path into a destination mounted filesystem path, with deterministic placement, verification, and forensic traceability.

## Product note (2026-03-05)
Keep verifiable transfer and catalog placement as separable capabilities:
- Capability A: verifiable copy from source to destination.
- Capability B: catalog placement by date/camera schema (`YYYY/YYYYMM/<CameraLabel>/<MediaType>`).

Default remains a single end-to-end ingest flow (A + B), but architecture should keep capabilities separable.
The app may expose workflows that are intentionally not available from the CLI surface.

## 2) User-visible outcome
Given a readable source card and a writable destination mount:
- The user selects a source and a destination in the app. The app can detect a card, and it can remember the last destination.
- The app scans the source and plans the destination paths. It shows an inventory and the planned path behavior before it copies any file.
- The user starts the ingest. The engine copies each file to staging, verifies it by read-back hash, then commits it to its final library path.
- On success, the result is `VERIFIED` and gives the receipt path. The user can open the receipt and the destination afterward.
- On failure, the result gives the failed phase, a summary of the reason, the receipt path, and the staging path.
- The CLI runs the same engine with one command. It reports the same facts. It is a complementary interface and may offer fewer options than the app (see Section 11).

`VERIFIED` has a precise meaning. See Section 8.

## 3) Non-negotiable invariants
These invariants MUST hold for every run. Other documents refer to them by ID (I-1 to I-10).
To change an invariant, the owner must approve the change, and this section must change in the same commit.

### I-1. The source card is never changed
The code never opens a card file for writing, deleting or renaming. Source card content is never deleted or modified.
macOS gives the card its normal read, write and execute permissions. The code does not rely on a read-only mount, so the code itself must stay read-only for the card.

### I-2. The library is never overwritten
Existing final library files are never overwritten. Final paths are append-only (see Section 7).
- If the existing file has the same hash, the incoming file is a duplicate. It is not copied.
- If the hash is different, the incoming file gets a sequence suffix.
- If another process takes the name between the check and the move, the move fails and the code looks for the next free name (see Section 7).

### I-3. Every file goes through staging, in a fixed order
All copied files land in staging first. A file reaches its final path only after it passes verification.
The order is: scan, plan, copy to staging (with hash), verify, commit, finalize. No file skips staging. No file skips verification (see Section 11).

### I-4. Embedded metadata is preserved
Media payload bytes are preserved end to end. EXIF and container metadata are never rewritten or removed during ingest.

Exception: Film Mode. Film Mode is app-only, off by default, and chosen for each ingest (see Section 5). Film Mode deliberately rewrites EXIF/TIFF date and camera fields, and a set of optional descriptive fields (film stock, ISO, lens, shot-at-ISO, development notes, scanner, creator, copyright), on the committed copy of photos in the batch. This is a user-initiated override for digitized film. In digitized film, the source EXIF shows the digitizing camera and not the original shoot.
- The original source file is never touched.
- Film Mode rewrites only JPEG, TIFF, HEIC and PNG files. RAW files keep their original embedded EXIF (known limitation, see Section 5).
- Film Mode does not change filesystem timestamps (see I-8).

Known limitations of Film Mode (accepted 2026-10-04):
- The code rewrites the staged file after verification and just before the move to the final path. Nothing hashes the file again after the rewrite. The committed bytes are not the bytes that passed verification.
- A Film Mode file never matches an existing library file by hash. A second ingest of the same file is not classified as a duplicate.

### I-5. Verification cannot be turned off or skipped
Verification is defined in Section 8. No user-facing setting may disable or weaken it. No stored state (ledger, manifest or cache) may let a file skip it. See ADR 0001 (`docs/adr/0001-no-verification-opt-out.md`).
The engine has an internal `verifyAfterCopy` flag. Only tests may set it to `false`. Production code must set it to `true`.

### I-6. The receipt is always written
Receipt logging starts at session start and is appended through all phases, including failures. The code flushes the receipt to disk after each event.
- The primary sink is the destination receipts path. If a write to it fails, the code switches to the local temp fallback and continues to log.
- If neither sink can be opened at session start, the session does not start.

### I-7. A failed run keeps its evidence
After a failure or a cancel, the code keeps the staging folder and the receipt. It never overwrites anything during recovery. Files that the run already committed stay in the library.
Section 9 defines each failure case.

### I-8. Filesystem dates are preserved
Committed final files keep the source filesystem `modification date`. They keep the source `creation date` when the destination filesystem supports it. Film Mode does not change filesystem dates.

### I-9. Writes go only to allowed places
Writes are limited to:
- the destination staging folder
- the destination receipts folder (the receipt, and the optional PDF summary)
- newly created final library files and directories
- the local temp receipt fallback, only if the destination receipts folder becomes unavailable

The only deletions are staging files and folders that the same session created (see Section 11).

### I-10. The path strategy is fixed at run start
The destination path strategy is snapshotted at run start. It does not change during the run.

## 4) Destination folder rules
Destination is a mounted filesystem path selected by the user.

### Final library schema
- v1 fixed hierarchy: `<DEST>/<chronological>/<camera?>/<media>/<compression?>/<filename>`
- `chronological` is mandatory and selectable:
  - `YYYY/YYYYMM` (default)
  - `YYYY/MM`
- `camera` is optional (default enabled).
- `media` is mandatory:
  - `Photos`
  - `Videos`
- `compression` is optional and photo-only (default disabled):
  - `RAW`
  - `Non-RAW`
- RAW classification rule (when split is enabled):
  - if photo extension is in RAW allowlist, route to `RAW`
  - otherwise route to `Non-RAW`
- The final filename is the source filename. The only change is a collision suffix (Section 7).

### Audio (v1 exception)
Audio is a third media kind, but does not use the `<camera?>/<media>` shape above. Audio candidates always land in a single flat bucket:
- `<DEST>/<chronological>/audio/<filename>`
- No camera-label folder (audio is not subject to camera/device inference in v1 — see Section 6).
- No further media-type subfolder (the `audio` folder itself is the leaf directory).
- `compression` does not apply (photo-only).
- This is a deliberate v1 simplification: getting audio into the correct chronological bucket matters now; per-device folder structure may be introduced later without disturbing already-committed files (new structure would only apply going forward).

### Unsorted fallback
If timestamp cannot produce a valid year/month bucket:
- use the same toggles as dated paths:
  - `<DEST>/_unsorted/<camera?>/<media>/<compression?>/<filename>`
  - Audio: `<DEST>/_unsorted/audio/<filename>`

### Internal operational folders
- Staging: `<DEST>/_ingest_staging/<SessionID>/...`
  - While a file is copied, it has a hidden temporary name in its staging folder. The name is `.rollkeep-<uuid>.tmp`. It has a fixed length and does not contain the filename, so a long filename cannot make it too long. The code renames it to `<filename>` only after the full copy.
- Receipts: `<DEST>/_ingest_receipts/<SessionID>.ndjson`
- Optional PDF summary: `<DEST>/_ingest_receipts/<SessionID>.summary.pdf` (written only when requested)
- The finalized summary is the `SUMMARY` event in the NDJSON receipt (Section 10). The engine writes no separate `<SessionID>.json` file. The CLI `--json` option prints the summary to standard output.
- Receipt failover (only when destination receipt path is unavailable): `<LOCAL_TMP>/rollkeep/_ingest_receipts/<SessionID>.ndjson`

## 5) Metadata rules and date fallback

### File type classification
- Photos: allowlisted still-image/raw extensions.
- Videos: allowlisted video extensions.
- Audio: allowlisted audio extensions (`wav`, `mp3`, `m4a`, `aac`, `caf`, `aif`, `aiff`).
- Sidecars: allowlisted companion extensions matched by basename to media files.
- Unknown/non-allowlisted photo extensions are not candidates and do not reach planning.
- The file type comes from the true trailing extension of the filename. Characters earlier in the name, such as a right-to-left override, do not change the type.

#### Scan rules
The scan decides which files become candidates.
- The source root must be a readable directory. If it is not, the session fails (Section 9).
- Hidden and system entries are ignored: any entry with the hidden flag, any path component that starts with `.`, and the names `$recycle.bin`, `system volume information` and `__macosx`.
- Symbolic links are never followed and never imported, in files or in directories. Each skipped link is recorded as a `SCAN_WARNING` with category `symbolic_link_skipped` (the receipt keeps at most 50 of these warnings). The link and its target stay out of the library.
- A file with an unknown extension is not a candidate. If it is 64 MiB or larger, its extension has 2 to 8 letters or digits, and it is in a typical media location (`DCIM/`, `PRIVATE/`, `AVCHD/`, `MP_ROOT/`, `MISC/`, `MOVIE/`, `VIDEO/`), the scan records a `SCAN_WARNING` with category `unknown_large_skipped_file` (at most 50). The warning helps the user find camera media with a new extension.
- A single unreadable file is not a candidate. The scan records it as an `ERROR` event in the `scan` phase and counts it in the error total. The run continues with the other files.
- Metadata extraction never stops a run. A malformed or oversized container structure (for example a box with a size that overflows) stops the parse. The file then follows the normal fallback rules for missing metadata and is ingested byte-identical.
- A text value from embedded video metadata that is longer than 128 UTF-8 bytes is not accepted. The file is labeled `unknown-camera`.
- The scan runs once. Section 9 defines what happens if a file changes between the scan and the copy.

#### WAV dual-role exception
`.wav` is the one extension that is not exclusively "media" or exclusively "sidecar" — its role is resolved per file by a same-directory, same-basename check against video files:
- If a video file with the same basename exists in the same directory (e.g. `CLIP_0012.MP4` next to `CLIP_0012.WAV` — the DJI Pocket 3 "high-quality companion audio" pattern), the WAV is treated as a **sidecar of that video**: it commits next to the video, inherits the video's media-type placement, and is not counted as a standalone Audio candidate.
- Otherwise, the WAV is a **standalone Audio candidate** like any other audio file.
- This is the one documented exception to the general rule that sidecar extensions are matched by basename to *an already-classified* media file — here the same extension can resolve either way depending on what's next to it.

### Capture date source of truth
Photos (priority order):
0. Film Mode override, if enabled for this ingest (app-only, off by default, declared once per run: month/year, camera required; film stock, ISO, lens, shot-at-ISO, development notes, scanner, creator, and copyright all optional). Always determines capture-date-source and destination-folder placement for every photo in the batch, RAW included. On-disk EXIF/TIFF metadata is only rewritten into the committed copy for JPEG/TIFF/HEIC/PNG — RAW formats (DNG, CR2, CR3, NEF, ARW, GPR, ORF, RW2, ...) keep their original embedded EXIF; this is a known limitation, tracked via `film_mode.exif_applied_count`/`exif_skipped_count` in the summary and surfaced in the launcher UI. Applies only to the committed copy, never the source. Marked `film_mode_override` in the receipt. See I-4 for the two further limitations (no hash after the rewrite, no duplicate match).
1. EXIF `DateTimeOriginal`
2. EXIF `CreateDate`
3. Filesystem `mtime` on source card (marked as fallback in receipt)

Videos (priority order):
1. Container metadata `creation_time` (or platform-equivalent)
2. Matched sidecar metadata timestamp (marked as sidecar source in receipt)
3. Filesystem `mtime` on source card (marked as fallback in receipt)

Audio (priority order):
1. Container metadata `creation_time` (read via AVFoundation; confirmed present and reliable for AAC/M4A recordings, generally absent for PCM WAV)
2. Filesystem `mtime` on source card (marked as fallback in receipt)
Audio has no sidecar-consult tier in v1 (standalone audio does not carry its own sidecars).

Sidecar consult rules:
- Sidecar metadata is only consulted when primary embedded video metadata is missing/insufficient.
- Sidecar pairing is same-directory + basename-based (sidecar extension allowlist), with a Sony clip XML variant that maps `<ClipStem>M01.XML` (and `M` + 2-3 digit variants) to `<ClipStem>.<VideoExt>`.
- Supported sidecar extensions include: `.THM`, `.XMP`, `.AAE`, `.XML`, `.SRT`, `.CPI`, `.NKSC`, `.DOP`, `.PP3`, `.JSON`.
- For camera identity (make/model/serial), sidecar metadata may fill missing video metadata fields.

Sidecar transfer rules:
- Matched sidecars are ingested as companion files through the same staging -> verify -> commit pipeline.
- Sidecars commit next to the associated media file in the same final library directory.
- When photo compression split is enabled, photo sidecars follow the associated media destination (`RAW` or `Non-RAW`).
- No-overwrite, duplicate, conflict-suffix, and receipt invariants apply to sidecars exactly as to media files.

Timezone policy:
- If metadata includes timezone/offset, use it.
- If metadata lacks timezone, interpret in runner-local timezone.

Preservation policy:
- Embedded metadata preservation is mandatory (I-4): EXIF/photo metadata and video container metadata must remain unchanged in committed files, except for Film Mode.
- Filesystem date preservation is mandatory for `mtime` and best-effort for `creation date` on filesystems that allow setting it (I-8).

## 6) Camera labeling rules
RollKeep supports mixed-camera cards.

Audio exemption (v1): Audio candidates are not subject to camera/device inference. Every standalone audio candidate is labeled `audio` unconditionally — no EXIF/container make-model lookup is attempted. This is a deliberate v1 scope limit (see Section 4 Audio exception); device-level audio labeling may be introduced later.

Inference rule (per file, Photos/Videos only):
- For each media file, infer camera identity from its own metadata (prefer photo EXIF; fallback to video metadata).
- Build label from the best available normalized model identifier; if model is unavailable, fall back to make.
- Do not append camera serial tokens to folder labels (serial remains in evidence/receipt fields).
- If missing/insufficient metadata for a file, use `unknown-camera` for that file only.
- Session-level `CAMERA_LABEL_DETECTED` becomes a distribution summary of labels and counts, not a single forced label.
- Camera inference always runs even when camera-folder grouping is disabled (for receipt/UI truthfulness).

Camera label constraints:
- ASCII only.
- Lowercase kebab-case.
- Remove path separators and reserved filesystem characters.
- Embedded video text values longer than 128 UTF-8 bytes are insufficient metadata (Section 5, scan rules).

### Card inventory policy
- Card-level camera assessment MUST use full-card inventory across all scanned candidate media files; sampled assessment is not allowed.
- Confidence scores and warning text are not emitted.
- User-facing and receipt decisions MUST be based on explicit facts:
  - detected labels + file counts
  - `unknown-camera` file count
- Mixed-camera cards are a supported normal case, not an automatic warning condition.

### User camera catalog (app-only)
Code→name resolution (the "build label from the best available normalized model identifier" step above) is backed by a user-owned catalog, not a catalog bundled with the app:
- Storage: a single JSON file at `~/Library/Application Support/RollKeep/CameraCatalog.json` (or the sandbox-container equivalent, should the app move to a sandboxed distribution), shaped `{"CODE": "Display Name"}`. Keys are normalized (trim + uppercase) the same way the inference rule's own lookup normalizes codes.
- Unique names (owner decision, 2026-10-05): the app does not save a name if its folder label equals the folder label of another entry. Two camera codes cannot share one library folder. The app shows the reason as text. A catalog that already has such entries (an older file, or an import) is not changed. The app only refuses new saves of a shared name.
- Ownership: the app is the sole writer — add/edit/delete/import/export are app-only capabilities per the architecture direction in AGENTS.md. The CLI and the shared engine read the resulting file but never write it.
- Ships empty: RollKeep does not bundle hardcoded vendor catalogs. A fresh install starts with zero entries. A camera code with no matching user entry surfaces as its own raw normalized code — never as `unknown-camera`, which stays reserved for files with missing/insufficient metadata, not for an unmapped-but-present code.
- Lookup precedence: user catalog (by uppercased code) first, then the raw model/make string as-is. There is no bundled fallback layer beneath the user catalog.
- Unreadable file: a malformed or unreadable catalog file is treated as empty for labeling (ingest never aborts over a label), surfaced as a warning (app: banner in Settings > Camera Labels; CLI: one stderr line), and never overwritten — before the app's first write it moves the bad file aside as `CameraCatalog.corrupt-<timestamp>.json`. A missing file is normal (empty catalog, no warning).
- Test/fixture seam: the environment variable `ROLLKEEP_CAMERA_CATALOG_PATH` overrides the file location so automated runs never read a developer's real catalog.
- Backup: the app provides explicit export (write the catalog JSON to a user-chosen location) and import (load a previously exported JSON file) actions. No automatic sync (iCloud or otherwise) in v1.
- Migration note: this is a breaking change in observed labels, not in stored data — final-library folder names already committed to disk are never touched. A camera code that resolved to a friendly name under a previously-bundled catalog will resolve to its raw code on any ingest performed after this ships, until the user re-adds that mapping in the new catalog.

## 7) Collision and duplicate handling
Invariant I-2: final paths are append-only and non-overwriting.

The plan and the commit both check for collisions. The plan reports the expected result. The commit decides the real result, because the library can change between the two steps.

If final path already exists:
- If existing file hash equals incoming hash:
  - classify as duplicate
  - do not copy/commit into final
  - record as `duplicate_not_copied` in receipt summary and per-file events
- If hash differs:
  - resolve by sequence suffix before extension: `name-1.ext`, `name-2.ext`, ...
  - choose first non-existing candidate
  - record conflict and chosen path in receipt

Rules for the commit step:
- The commit checks each file again against the real library. If a planned name is now taken, the commit applies the rules above again.
- The commit moves the file with a move that fails if the name exists. If the move fails because the name exists, the commit resolves the path again and retries.
- A duplicate found at commit time is not committed. The staged copy stays in staging until the session staging folder is removed (Section 11).
- The suffix search has a limit of 100,000 names. If the limit is reached, the commit fails for that file (Section 9).
- Name matching uses the filesystem. On macOS filesystems (HFS+, exFAT, APFS), names that differ only in Unicode normalization (NFC and NFD) are the same name, so they count as one file. The plan also compares names without case.

## 8) Verification definition (ROL-10)
A file is `verified` only when all are true:
1. SHA-256 computed during stream copy to staging.
2. SHA-256 recomputed by re-reading the staged file, after the copy has finished and the file has its staging name.
3. Hashes match and sizes match expected bytes.

The check re-reads the staged file. It does not re-read the final file after the move.
No user-facing setting can disable or weaken this check, and no stored state can skip it (I-5, ADR 0001).

Session `VERIFIED` means:
- every file that reached copy phase passed per-file verification, and
- commit completed without unhandled errors.

`VERIFIED` covers only files that reached the copy phase. It does not mean that every file on the card was ingested. Files that the scan skipped or could not read (Section 5, scan rules) are outside this claim. The receipt and the summary list them as warnings and errors, and the summary has an error count. A `VERIFIED` session can have a non-zero error count. A failure to remove the staging folder after success is one such error (Section 11).

Failure policy:
- Any verify failure stops session before commit of remaining work.

## 9) Failure rules
- Scan failure:
  - if source root unreadable: fail session
  - if per-file metadata extraction fails: record error and continue scanning
  - if a single file is unreadable: record error, skip the file and continue scanning
- Preflight failure:
  - if the source and destination overlap (Section 11): reject before any write
  - if the destination has less free space than the bytes to copy: fail in the `copy` phase before any file is copied. If the app cannot read the free space, it logs a warning and continues.
- Copy failure:
  - fail session, keep staging, keep receipt
  - the first failure stops the copy: files not yet started are not copied. Files that finished remain in staging.
  - these conditions are copy failures: a source file that is a symbolic link or not a regular file when the app opens it (the app opens it without following links); a source file whose size is different from the size in the scan; a read error or a write error; a staging name that already exists; a copied byte count that is different from the expected count
  - because the app copies each file under a hidden temporary name, a copy failure leaves no partial file under a staging name
- Verify failure:
  - fail session before further commits. No file is committed.
  - Copy and verify of all files finish before the first commit starts.
- Commit failure:
  - fail session immediately, do not overwrite, retain staging and receipt for recovery
  - files committed before the failure stay in the library. Files not yet committed stay in staging. The receipt records both groups.
- Cancel:
  - the user can cancel a run. The run stops at the next phase, file or chunk boundary and ends as a failed session with the reason "cancelled".
  - the code keeps staging and the receipt (I-7). Files already committed stay.
- Destination disconnect / disk full / permission errors:
  - fail with explicit phase and path context
  - preserve already-written receipt content
- Receipt failure:
  - if the destination receipt write fails during the run, the code switches to the local fallback (I-6) and the run continues
  - if no receipt sink can be opened at start, the session does not start
- Staging cleanup failure after a successful run:
  - record an error in the receipt and the error count. The session status stays completed.
- Exit codes (CLI): 0 success, 1 failure with no phase, 2 verify, 3 scan, 4 plan, 5 copy, 6 commit, 7 finalize.

## 10) Receipt contents and guarantees
Receipt is append-only NDJSON, flushed after each event.

### Required fields in every event
- `session_id`
- `event_index` (a counter that starts at 1 and increases by 1 for each event)
- `timestamp`
- `event_type`
- `phase` (`scan|plan|copy|verify|commit|finalize`)
- `data` (event payload)

### Minimum event set
- `SESSION_STARTED`
- `SCAN_SUMMARY`
- `CAMERA_LABEL_DETECTED`
- `PLAN_COMPUTED`
- `DIR_CREATED`
- `FILE_COPY_STARTED`
- `FILE_COPIED`
- `FILE_VERIFY_STARTED`
- `FILE_VERIFIED`
- `FILE_COMMIT_STARTED`
- `FILE_COMMITTED`
- `DUPLICATE_SKIPPED`
- `CONFLICT_RENAMED`
- `ERROR`
- `SUMMARY`
- `SESSION_FINISHED`

The engine also writes these events: `SCAN_PROGRESS`, `SCAN_WARNING`, `SCAN_FILE_LIST`, `VIDEO_METADATA_FALLBACK_USED` and `RECEIPT_PDF_WRITTEN`. A reader must ignore event types it does not know.

`SESSION_FINISHED` carries the final status (`completed` or `aborted`), the error count, the active receipt path and sink, and a `resume_hook` with the last event index and all receipt paths. The `resume_hook` is information only. No code resumes a session from it (Section 11).
A session that ended by a crash has no `SESSION_FINISHED` event.

### Required summary fields
The summary is the data of the `SUMMARY` event.
- `verified_ok`
- totals by media type (Photos, Videos, Audio)
- totals by outcome: copied, duplicate_not_copied, conflicts_renamed, errors
- bytes processed
- applied path scheme as human-readable template string (`path_scheme`)
- date range
- camera inventory summary (per-label distribution with file counts, known/unknown file counts)
- receipt sink transitions and all receipt paths used (destination and/or local fallback)
- `touched_paths` containing:
  - created directories
  - written staging files
  - written final files
  - move operations staging->final
  - deleted paths (the session staging folder, when the code removed it after a completed run)

## 11) Verification and commit pipeline contract
Execution order is fixed:
1. Scan
2. Plan
3. Copy to staging (+ hash while copying)
4. Verify staged files (rehash + size)
5. Commit to final library paths (with collision/duplicate rules)
6. Finalize receipt

No file may skip staging or skip verification.
Path strategy is resolved once at run start and must not change during the run.
Copy and verify run for all files before the first commit starts. Commits run one file at a time.

Finalize:
- After a completed run that is not a dry run, the code removes the session staging folder (`<DEST>/_ingest_staging/<SessionID>`). It also removes `<DEST>/_ingest_staging` if that folder is then empty.
- After a failed run, a cancelled run or a dry run, the code removes nothing.
- This staging removal is the only cleanup that the engine does. No setting controls it.
- If a commit must copy a file across volumes because a move is not possible, the code copies the file to the final path, then removes the staged file. This fallback does not overwrite (the copy fails if the name exists).

### Run modes and lifecycle

#### Overlap preflight
The source and the destination must be different folders with no nesting. The check resolves symbolic links and then compares path components. It rejects these cases: source equals destination; destination inside source; source inside destination.
- The check runs before the session starts. A rejected run writes nothing: no receipt, no staging folder, no change to the source.
- The message says: "Source and destination must be different folders with no nesting."
- The check is in the CLI and in the app. It is not in the engine. Every surface that starts an ingest must call it. The owner accepted that the engine has no second check (`docs/known-issues.md`, KI-4).

#### Dry run
A dry run does the scan and the plan, and it stops.
- It writes only the receipt, and the PDF summary if requested. It creates no staging folder, no library folder and no library file. The receipt events for copy, verify and commit have `executed: false`.
- The plan marks duplicates and renames conflicts against the files that already exist in the destination.
- The final status is `completed`. The status label is `DRY RUN (scan+plan)`. It is never `VERIFIED`.
- The counts for copied, verified and committed are 0. `verified_ok` is false. The idempotency classification is `dry_run_not_applicable`.

#### Crash and restart
If the process stops without finishing (a crash or a kill), the receipt has no `SESSION_FINISHED` event, and the staging folder stays.
- The app does not resume a session. It does not remove old staging folders. It keeps them untouched until the user removes them.
- The next run is a new session with a new `SessionID`. It scans, copies and verifies everything again (I-5, ADR 0001). Files that an earlier run already committed are classified as duplicates.
- A run of the same card after a completed run commits no new files, and its idempotency classification is `idempotent_rerun`.

#### Command-surface note
- App is the primary product surface.
- CLI is a complementary engine interface and may intentionally expose a narrower command set than the app.
- Internally keep copy/verify and catalog planning as separate modules so app and CLI surfaces can evolve without breaking invariants.

## 12) Acceptance criteria mapping
This spec explicitly covers:
- folder rules: Sections 4 and 11
- camera labeling rules: Section 6
- scan rules: Section 5
- failure rules: Section 9
- verification definition: Section 8
- receipt contents: Section 10
- run modes (overlap preflight, dry run, crash and restart, cancel): Sections 9 and 11
- explicit invariants:
  - I-1 no change to the source card: Section 3
  - I-2 no overwrite in library: Sections 3 and 7
  - I-3 staging, fixed order: Sections 3 and 11
  - I-4 embedded metadata preserved: Sections 3 and 5
  - I-5 verification mandatory: Sections 3 and 8
  - I-6 receipt always written: Sections 3 and 10
  - I-7 failed run keeps evidence: Sections 3 and 9
  - I-8 filesystem dates preserved: Sections 3 and 5
  - I-9 writes only to allowed places: Sections 3 and 11
  - I-10 path strategy snapshot lock: Sections 3, 4, 10, 11

### Behavior to test map
| Behavior | Section | Test |
| --- | --- | --- |
| Baseline ingest, rerun gives duplicates, source unchanged | 7, 8, I-1 | `scripts/release-smoke-test.sh` |
| Path matrix, `_unsorted`, sidecars, rerun | 4, 5 | `scripts/existing-hdd-e2e-test.sh` |
| Disconnect, disk full, receipt failover | 9, I-6 | `scripts/e2e-fault-injection-test.sh` |
| Verify failure halts commit | 8, 9 | `scripts/e2e-verify-failure-test.sh` |
| Dates, writes only to allowed places | I-8, I-9 | `scripts/e2e-timestamp-and-write-audit-test.sh` |
| Crash and restart | 11 | `scripts/e2e-crash-restart-recovery-test.sh` |
| Dry run | 11 | `scripts/e2e-dry-run-truthfulness-test.sh` |
| Overlap preflight | 11 | `scripts/e2e-overlap-preflight-test.sh` |
| Symbolic links | 5 | `scripts/e2e-symlink-skip-test.sh` |
| Unreadable source file | 5 | `scripts/e2e-unreadable-source-test.sh` |
| Unicode normalization | 7 | `scripts/e2e-unicode-normalization-test.sh` |
| Hostile filenames (dry run only; see KI-1) | 5 | `scripts/e2e-hostile-filenames-test.sh` |
| Crafted container box | 5 | `scripts/e2e-boxwalker-overflow-crash-test.sh` |
| Oversized metadata text | 5, 6 | `scripts/e2e-metadata-length-bomb-test.sh` |
| Launcher end to end | 2 | `scripts/app-e2e-launcher-test.sh` |

## Known issues
Bugs and gaps are not part of this spec. They are in `docs/known-issues.md`.
