# rollkeep

`rollkeep` is a Swift command-line tool for media ingest.

Current status: end-to-end ingest is implemented: scan + plan + staging copy + optional read-back verification + commit to final library paths.

## Destination layout

- Dated photos: `<DEST>/YYYY/MMYYYY/<CameraLabel>/Photos/<filename>`
- Dated videos: `<DEST>/YYYY/MMYYYY/<CameraLabel>/Videos/<filename>`
- Unsorted photos (missing date bucket): `<DEST>/_unsorted/<CameraLabel>/Photos/<filename>`
- Unsorted videos (missing date bucket): `<DEST>/_unsorted/<CameraLabel>/Videos/<filename>`
- Staging mirror root: `<DEST>/_ingest_staging/<SESSION_ID>/...`

## Implemented functionality

- Swift Package executable: `rollkeep`
- Argument parsing using Apple Swift Argument Parser for:
  - `--source <path>`
  - `--dest <path>`
- `--dry-run`
- `--md` (optional Markdown summary next to receipt)
- `--verbose`
- `--skip-verify` (disable staged read-back verification)
- `--max-parallel-copies <n>` (bounded staging copy concurrency)
- `--json` (print final CLI summary as JSON)
- `--config <path>` (optional placeholder for later implementation)
- `-h`, `--help`
- Source scanning with recursive enumeration
- Media detection via extension allowlists (photos/videos)
- Hidden/system exclusion (for example `.Trashes`, `System Volume Information`, dot-prefixed paths)
- Deterministic file-list ordering in scan output
- Per-photo EXIF extraction via `ImageIO`:
  - capture datetime from `DateTimeOriginal`, fallback to `CreateDate`
  - camera identifiers (`make`, `model`, `serial`) when present
  - `_unsorted` plan bucket hint when EXIF datetime is missing
- EXIF datetime parsing timezone policy:
  - use metadata offset when present
  - interpret missing-offset values in runner-local timezone
- Per-file stats collection (`path`, `size`, `mtime`)
- Scan summary metrics (counts + bytes by media type)
- Receipt writing as NDJSON:
  - destination sink: `<DEST>/_ingest_receipts/<SESSION_ID>.ndjson`
  - fallback sink: `<LOCAL_TMP>/rollkeep/_ingest_receipts/<SESSION_ID>.ndjson` when destination receipt path is unavailable
- Explicit scan errors written to logs and receipt (`ERROR` events)

## Requirements

- macOS with Xcode Command Line Tools (Swift toolchain available)

## Run

From the repository root:

```bash
swift run rollkeep --help
```

Dry-run example:

```bash
swift run rollkeep --source /Volumes/SD --dest /Volumes/Media --dry-run
```

Dry-run with Markdown summary export:

```bash
swift run rollkeep --source /Volumes/SD --dest /Volumes/Media --dry-run --md
```

With optional config path:

```bash
swift run rollkeep --source /Volumes/SD --dest /Volumes/Media --dry-run --config ./rollkeep.yml
```

## Build and run binary directly

```bash
swift build
./.build/debug/rollkeep --help
./.build/debug/rollkeep --source /Volumes/SD --dest /Volumes/Media --dry-run
```

Inspect the latest receipt file:

```bash
ls -lt /Volumes/Media/_ingest_receipts
tail -n 50 /Volumes/Media/_ingest_receipts/<SESSION_ID>.ndjson
```

## Expected behavior (current)

- `rollkeep --help` prints usage and exits `0`.
- `rollkeep --source ... --dest ... --dry-run` performs a real scan and exits `0` on scan success.
- Logs are structured JSON lines (`timestamp`, `level`, `message`, `component`, and relevant fields).
- CLI always prints a final ingest summary with:
  - phase timings (`scan`, `plan`, `copy`, `verify`, `commit`, `finalize`)
  - key counts (candidates, copied/verified/committed, duplicates/conflicts, errors)
  - receipt path and sink
- `--json` prints that final summary as machine-readable JSON instead of human-readable text.
- A receipt file is always attempted and includes:
  - `SESSION_STARTED`
  - `SCAN_SUMMARY`
  - `SCAN_FILE_LIST`
  - `ERROR` (when present)
  - `SESSION_FINISHED`
- `SCAN_FILE_LIST` includes photo metadata fields:
  - `capture_datetime` (`ISO-8601` string or `"missing"`)
  - `capture_datetime_source` (`DateTimeOriginal|CreateDate|missing`)
  - `camera_make`, `camera_model`, `camera_serial`
  - `plan_bucket` (`dated|_unsorted`)
- With `--md`, a human-readable summary is also written:
  - `<RECEIPT_DIR>/<SESSION_ID>.summary.md`
- Source-root unreadable errors fail the run with non-zero exit and are recorded in receipt.
- Per-file unreadable/stat failures are recorded as explicit errors and scanning continues.
- In non-dry-run mode, files planned for `stage_and_commit` are copied into `<DEST>/_ingest_staging/<SESSION_ID>/...` using chunked streaming copy.
- During copy, SHA-256 is computed over source bytes and stored in receipt events.
- Verification re-hashes staged content by default; `--skip-verify` disables that phase.
- Copy failures abort the session before commit and keep staging/receipt artifacts.
- Commit moves verified files from staging to final paths without overwrite.
- Successful non-dry-run sessions remove `<DEST>/_ingest_staging/<SESSION_ID>` after commit.
- Commit collisions are resolved deterministically with `-1`, `-2`, ... suffixes.
- Commit failures abort the session and receipt events include moved vs remaining files.
- On failure, final summary includes failure phase, receipt path, staging session path, and first recorded errors.
- Exit codes:
  - `0`: success
  - `2`: verify failure
  - `3`: scan failure
  - `4`: plan failure
  - `5`: copy failure
  - `6`: commit failure
  - `7`: finalize failure
  - `1`: generic failure fallback

## Camera signal (user-facing)

The Markdown summary is intentionally word-based (not numeric) in `Camera Identifier Coverage`:

- `strong single-camera signal`: camera metadata is consistent and one label clearly dominates.
- `moderate single-camera signal`: one camera leads, but metadata is less complete or more varied.
- `weak single-camera signal`: some camera evidence exists, but it is noisy or fragmented.
- `mixed-camera card`: multiple camera signatures are present on the card.
- `insufficient camera metadata`: camera identifiers are mostly missing.

Use this as a quick trust indicator for the detected card label.

Technical note:
- NDJSON receipt events still include numeric confidence values for diagnostics and future tuning.

## Run tests

```bash
swift test
```

## Notes

- `--dry-run` runs scan+plan only and does not execute staging copy.
- The destination path must be writable for primary receipt output; otherwise local temp fallback is used.
