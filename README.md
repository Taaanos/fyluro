# rollkeep

`rollkeep` is a Swift command-line tool for media ingest.

Current status: scanner MVP is implemented (scan + receipt logging). Copy/verify/commit pipeline is not implemented yet.

## Implemented functionality

- Swift Package executable: `rollkeep`
- Argument parsing using Apple Swift Argument Parser for:
  - `--source <path>`
  - `--dest <path>`
  - `--dry-run`
  - `--verbose`
  - `--config <path>` (optional placeholder for later implementation)
  - `-h`, `--help`
- Source scanning with recursive enumeration
- Media detection via extension allowlists (photos/videos)
- Hidden/system exclusion (for example `.Trashes`, `System Volume Information`, dot-prefixed paths)
- Deterministic file-list ordering in scan output
- Basic per-file stats collection (`path`, `size`, `mtime`)
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
- A receipt file is always attempted and includes:
  - `SESSION_STARTED`
  - `SCAN_SUMMARY`
  - `SCAN_FILE_LIST`
  - `ERROR` (when present)
  - `SESSION_FINISHED`
- Source-root unreadable errors fail the run with non-zero exit and are recorded in receipt.
- Per-file unreadable/stat failures are recorded as explicit errors and scanning continues.
- Copy/verify/commit are not implemented yet.

## Run tests

```bash
swift test
```

## Notes

- `--dry-run` currently affects only messaging; current behavior is scan-only either way.
- The destination path must be writable for primary receipt output; otherwise local temp fallback is used.
