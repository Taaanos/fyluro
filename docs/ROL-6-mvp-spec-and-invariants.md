# ROL-6: MVP Spec and Invariants

Status: MVP baseline for implementation
Owner: Product
Scope: CLI ingest only

## 1) Purpose
Define non-negotiable behavior for ingesting media from a source card path into a destination mounted filesystem path, with deterministic placement, verification, and forensic traceability.

## Product note (2026-03-05)
Keep verifiable transfer and catalog placement as separable capabilities:
- Capability A: verifiable copy from source to destination.
- Capability B: catalog placement by date/camera schema (`YYYY/MMYYYY/<CameraLabel>/<MediaType>`).

MVP default remains a single end-to-end ingest flow (A + B), but architecture and CLI surface should not couple them permanently.

Post-MVP direction:
- Support copy-only mode (A without B) for users who only want safe offload.
- Support catalog-only mode over an existing directory tree (B on already-copied files).

## 2) User-visible outcome
Given a readable source card and writable destination mount:
- User runs one ingest command.
- Tool scans and plans destination paths.
- Tool copies to staging, verifies by read-back hash, then commits to final library paths.
- Tool prints `VERIFIED` on success plus receipt path.
- Tool prints failure phase, reason summary, receipt path, and staging path on failure.

## 3) Non-negotiable invariants
These invariants MUST hold for every run:
- No delete on card: source card content is never deleted or modified.
- No overwrite in library: existing final library files are never overwritten.
- Staging required: all copied files land in staging first, then commit to final path only after verification.
- Receipt always written: receipt logging starts at session start and is appended throughout all phases, including failures.
  - Primary sink is destination receipts path; on destination receipt-path write failure, switch to local temp fallback and continue logging.
- Destination-constrained writes only, except receipt failover: writes are limited to destination staging, destination receipts, newly created final library files/directories, and local temp receipt fallback if destination receipts become unavailable.

## 4) Destination folder rules
Destination is a mounted filesystem path selected by the user.

### Final library schema
- Photos: `<DEST>/YYYY/MMYYYY/<CameraLabel>/Photos/<filename>`
- Videos: `<DEST>/YYYY/MMYYYY/<CameraLabel>/Videos/<filename>`

Where:
- `MMYYYY` is month/year (example: `022026`).
- `CameraLabel` is folder-safe ASCII slug.

### Unsorted fallback
If timestamp cannot produce a valid year/month bucket:
- Photos: `<DEST>/_unsorted/<CameraLabel>/Photos/<filename>`
- Videos: `<DEST>/_unsorted/<CameraLabel>/Videos/<filename>`

### Internal operational folders
- Staging: `<DEST>/_ingest_staging/<SessionID>/...`
- Receipts: `<DEST>/_ingest_receipts/<SessionID>.ndjson`
- Optional finalized summary: `<DEST>/_ingest_receipts/<SessionID>.json`
- Receipt failover (only when destination receipt path is unavailable): `<LOCAL_TMP>/rollkeep/_ingest_receipts/<SessionID>.ndjson`

## 5) Metadata rules and date fallback

### File type classification
- Photos: allowlisted still-image/raw extensions.
- Videos: allowlisted video extensions.
- Hidden/system files are ignored by default.

### Capture date source of truth
Photos (priority order):
1. EXIF `DateTimeOriginal`
2. EXIF `CreateDate`
3. Filesystem `mtime` on source card (marked as fallback in receipt)

Videos (priority order):
1. Container metadata `creation_time` (or platform-equivalent)
2. Filesystem `mtime` on source card (marked as fallback in receipt)

Timezone policy for MVP:
- If metadata includes timezone/offset, use it.
- If metadata lacks timezone, interpret in runner-local timezone.

## 6) Camera labeling rules
MVP supports mixed-camera cards.

Inference rule (per file):
- For each media file, infer camera identity from its own metadata (prefer photo EXIF; fallback to video metadata).
- Build label from best available model identifier and stable token when present.
- If missing/insufficient metadata for a file, use `unknown-camera` for that file only.
- Session-level `CAMERA_LABEL_DETECTED` becomes a distribution summary of labels and counts, not a single forced label.

Camera label constraints:
- ASCII only.
- Lowercase kebab-case.
- Remove path separators and reserved filesystem characters.

### Confidence heuristic (temporary MVP policy)
- Keep confidence fields for now as diagnostic metadata.
- Confidence MUST NOT gate ingest correctness, safety invariants, copy/verify/commit, or failure handling.
- User-facing decisions should prefer explicit data (detected labels + counts + mixed-camera flag) over numeric confidence values.

Post-CLI challenge item (required revisit):
- Re-evaluate whether confidence adds user value at all.
- Evaluate replacing sampled camera assessment with full-card camera inventory (scan all candidate files for camera identifiers) to provide exact label distributions.
- If full inventory is adopted, document the measured runtime impact and acceptable performance bounds before making it default.

## 7) Collision and duplicate handling
Invariant: final paths are append-only and non-overwriting.

If final path already exists:
- If existing file hash equals incoming hash:
  - classify as duplicate
  - do not copy/commit into final
  - record as `duplicate_not_copied` in receipt summary and per-file events
- If hash differs:
  - resolve by sequence suffix before extension: `name-1.ext`, `name-2.ext`, ...
  - choose first non-existing candidate
  - record conflict and chosen path in receipt

## 8) Verification definition (ROL-10)
A file is `verified` only when all are true:
1. SHA-256 computed during stream copy to staging.
2. SHA-256 recomputed by re-reading staged file.
3. Hashes match and sizes match expected bytes.

Session `VERIFIED` means:
- every file that reached copy phase passed per-file verification, and
- commit completed without unhandled errors.

MVP failure policy:
- Any verify failure stops session before commit of remaining work.

## 9) Failure rules
- Scan failure:
  - if source root unreadable: fail session
  - if per-file metadata extraction fails: record error and continue scanning
- Copy failure:
  - fail session, keep staging, keep receipt
- Verify failure:
  - fail session before further commits
- Commit failure:
  - fail session immediately, do not overwrite, retain staging and receipt for recovery
- Destination disconnect / disk full / permission errors:
  - fail with explicit phase and path context
  - preserve already-written receipt content

## 10) Receipt contents and guarantees
Receipt is append-only NDJSON, flushed after each event.

### Required fields in every event
- `session_id`
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
- `SESSION_FINISHED`

### Required summary fields
- `verified_ok`
- totals by media type
- totals by outcome: copied, duplicate_not_copied, conflicts_renamed, errors
- bytes processed
- date range
- camera labels summary (label, confidence/source, file count)
- receipt sink transitions and all receipt paths used (destination and/or local fallback)
- `touched_paths` containing:
  - created directories
  - written staging files
  - written final files
  - move operations staging->final
  - any deleted paths (only if cleanup was explicitly enabled)

## 11) Verification and commit pipeline contract
Execution order is fixed:
1. Scan
2. Plan
3. Copy to staging (+ hash while copying)
4. Verify staged files (rehash + size)
5. Commit to final library paths (with collision/duplicate rules)
6. Finalize receipt

No file may skip staging or skip verification.

Command-surface note:
- MVP can expose one primary command for end-to-end ingest.
- Internally keep copy/verify and catalog planning as separate modules to allow future `copy-only` and `catalog-only` commands without breaking invariants.

## 12) Acceptance criteria mapping
This spec explicitly covers:
- folder rules: Sections 4 and 11
- camera labeling rules: Section 6
- failure rules: Section 9
- verification definition: Section 8
- receipt contents: Section 10
- explicit invariants:
  - no delete on card: Section 3
  - no overwrite in library: Sections 3 and 7
  - staging usage: Sections 3 and 11
  - receipt always written: Sections 3 and 10
