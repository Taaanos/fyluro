# rollkeep

`rollkeep` is a macOS app for media ingest, with a complementary Swift CLI engine.

Product status: `rollkeep` is now a simple niche product for reliable camera-card ingest, not an MVP prototype. The app is the primary product surface, and the CLI is a complementary tool for scripted and terminal-based workflows. Both use the same end-to-end ingest flow: scan + plan + staging copy + read-back verification + commit to final library paths.

## What The App Does

Offload your camera cards with proof.

`rollkeep` is built for photographers and creators who need a repeatable ingest flow, not just a file copy. It scans a source card, plans deterministic destination paths, copies into a staging area first, verifies staged bytes, and only then commits into the library using non-overwrite rules. Every run also writes an append-only receipt so you can audit what was scanned, copied, verified, skipped as duplicate, or failed.

## Why Verification Matters

A plain drag-and-drop copy can look successful while still leaving you with silent corruption, partial copies, missing files, or accidental path collisions discovered later. `rollkeep` adds explicit read-back verification and receipt evidence so ingest quality is measurable at transfer time, not guessed afterward.

Verification works in two steps: while bytes stream from source to staging, `rollkeep` computes a SHA-256 hash without an extra source read; then it re-reads the staged file and computes SHA-256 again, and only marks the file verified if hash and byte count both match. In practice, the first hash is usually hidden behind I/O time, while the staged read-back is the extra full-read cost that buys integrity evidence before commit.

The user value is direct:

- Better evidence before you format cards.
- Faster failure detection with phase-specific errors (`scan`, `copy`, `verify`, `commit`).
- Safer library growth with no-overwrite behavior and deterministic conflict handling.
- Traceable ingest history you can reference for support, recovery, or client delivery accountability.

## Destination layout

- Dated photos: `<DEST>/YYYY/YYYYMM/<CameraLabel>/Photos/<filename>`
- Dated videos: `<DEST>/YYYY/YYYYMM/<CameraLabel>/Videos/<filename>`
- Unsorted photos (missing date bucket): `<DEST>/_unsorted/<CameraLabel>/Photos/<filename>`
- Unsorted videos (missing date bucket): `<DEST>/_unsorted/<CameraLabel>/Videos/<filename>`
- Staging mirror root: `<DEST>/_ingest_staging/<SESSION_ID>/...`

## Implemented functionality

- Swift Package executables:
  - `rollkeep-launcher` (macOS app entrypoint)
  - `rollkeep` (complementary CLI engine)
- Argument parsing using Apple Swift Argument Parser for:
  - `--source <path>` (optional: auto-detected from `/Volumes` when omitted)
  - `--dest <path>` (optional: remembered mounted destination when omitted)
- `/Volumes` source-card heuristics:
  - `DCIM` directory presence
  - removable-volume hint when available from the filesystem
- `/Volumes` watcher for newly mounted cards when `--source` is omitted
- Manual override pickers for source and destination selection in interactive sessions:
  - `--pick-source`
  - `--pick-dest`
- Destination memory inferred from mounted `_ingest_receipts` activity (no separate state file)
- `--dry-run`
- `--pdf` (optional PDF summary next to receipt)
- `--verbose`
- `--max-parallel-copies <n>` (bounded staging copy concurrency)
- `--detect-timeout-seconds <n>` (`0` waits indefinitely for new card mount)
- `--json` (print final CLI summary as JSON)
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

From the repository root, launch the app:

```bash
swift run rollkeep-launcher
```

Complementary CLI usage:

```bash
swift run rollkeep --help
```

Dry-run example:

```bash
swift run rollkeep --source /Volumes/SD --dest /Volumes/Media --dry-run
```

Auto-detect source card + reuse remembered destination:

```bash
swift run rollkeep --dry-run
```

Auto-detect source card with picker override and a 90s watch timeout:

```bash
swift run rollkeep --dry-run --pick-source --detect-timeout-seconds 90
```

Dry-run with PDF summary export:

```bash
swift run rollkeep --source /Volumes/SD --dest /Volumes/Media --dry-run --pdf
```

## Build and run binary directly

```bash
swift build
./.build/debug/rollkeep --help
./.build/debug/rollkeep --source /Volumes/SD --dest /Volumes/Media --dry-run
```

## Package A macOS App Bundle

Build a versioned Apple Silicon app bundle, release zip, and SHA-256 checksum:

```bash
scripts/package-macos-app.sh --version 0.1.0
```

The packaging script also converts `assets/macos/AppIcon.png` into the bundled macOS app icon.

Artifacts are written to `dist/`:

- `dist/RollKeep.app`
- `dist/RollKeep-0.1.0-macos-arm64.zip`
- `dist/RollKeep-0.1.0-macos-arm64.zip.sha256`

Install locally by unzipping the archive and dragging `RollKeep.app` into `~/Applications` or `/Applications`.

The packaged app is unsigned in this release flow. On first launch, macOS may block it until you:

- right-click `RollKeep.app` in Finder and choose `Open`, or
- open `System Settings > Privacy & Security` and allow it with `Open Anyway`

The app bundle embeds both executables:

- `rollkeep-launcher` as the macOS app entrypoint
- `rollkeep` beside it inside `RollKeep.app/Contents/MacOS/`

That bundled layout lets the launcher find the CLI without `swift run` or a PATH-installed binary.

For a GitHub Release, upload the generated `.zip` and `.sha256` files from `dist/`.

## Local Release Flow

Run the end-to-end release flow in one command:

```bash
scripts/release-cut.sh --bump patch
```

Or set the target version explicitly:

```bash
scripts/release-cut.sh --version 0.2.0
```

`release-cut.sh` requires a clean git working tree before it starts, then it:

- runs `swift test`
- runs local ingest smoke checks against `Tests/TestingDirs/SD_CARD1` and `Tests/TestingDirs/SD_CARD2`
- runs existing-HDD ingest e2e checks with preseeded duplicate/conflict fixtures under `Tests/TestingDirs/E2E_EXISTING_HDD_*`
- runs launcher app-surface e2e checks via `scripts/app-e2e-launcher-test.sh`
- builds `dist/RollKeep.app` and verifies it via `scripts/release-app-smoke-test.sh`, which relocates a copy of the packaged app outside the repo and runs a real ingest through its packaged CLI binary — this is what catches packaging bugs that in-repo testing can't (e.g. a resource that only resolves on the machine that built the release)
- builds `dist/RollKeep-<version>-macos-arm64.zip`
- builds `dist/RollKeep-<version>-macos-arm64.zip.sha256`
- updates `VERSION`
- prepends a generated release section to `CHANGELOG.md`
- commits `VERSION` and `CHANGELOG.md` with `chore: release v<version>`
- publishes the branch, tag, and GitHub release assets via `gh`

E2E runtime defaults used by the release flow:

- `scripts/existing-hdd-e2e-test.sh` defaults to a fast fixture profile (`ROLLKEEP_E2E_FIXTURE_PROFILE=fast`) and `4` workers (`ROLLKEEP_E2E_WORKERS=4`).
- `scripts/app-e2e-launcher-test.sh` defaults to `4` test workers (`ROLLKEEP_APP_E2E_WORKERS=4`).

`scripts/release-app-smoke-test.sh` also supports an opt-in `--with-launcher-check` flag that launches the packaged `rollkeep-launcher` against a disposable fake "SD card" to verify the automatic-scan-on-launch path directly. It is **not** run automatically by the release flow (it depends on window-server/session behavior on the machine running it), so run it manually before shipping any release that touches launcher startup or auto-scan code:

```bash
scripts/release-app-smoke-test.sh --version 0.2.0 --with-launcher-check
```

Run existing-HDD E2E in full-fixture serial mode when you need exhaustive parity:

```bash
ROLLKEEP_E2E_FIXTURE_PROFILE=full ROLLKEEP_E2E_WORKERS=1 scripts/existing-hdd-e2e-test.sh
```

Useful flags:

- `--dry-run`: validate tests and packaging without changing release metadata
- `--no-publish`: stop after local commit and skip git push + GitHub Release
- `--commit-message "...":` override the default release commit message

```bash
scripts/release-cut.sh --bump patch --no-publish
```

If you want the previous split workflow, keep using:

```bash
scripts/release-prepare.sh --bump patch
git add VERSION CHANGELOG.md
git commit -m "chore: release v0.2.0"
scripts/release-publish.sh --version 0.2.0
```

`release-publish.sh`:

- reads the version from `VERSION` by default
- requires a clean git working tree
- creates an annotated `v<version>` tag locally if it does not exist yet
- pushes the current branch and tag to `origin`
- creates or updates the GitHub Release with notes extracted from `CHANGELOG.md`
- uploads `dist/*.zip` and `dist/*.sha256` with `gh`

Authenticate `gh` once before publishing:

```bash
gh auth login
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
  - idempotency classification (`idempotent_rerun`, `new_files_committed`, or dry-run/failure variants)
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
- With `--pdf`, a human-readable summary is also written:
  - `<RECEIPT_DIR>/<SESSION_ID>.summary.pdf`
- Source-root unreadable errors fail the run with non-zero exit and are recorded in receipt.
- Per-file unreadable/stat failures are recorded as explicit errors and scanning continues.
- In non-dry-run mode, files planned for `stage_and_commit` are copied into `<DEST>/_ingest_staging/<SESSION_ID>/...` using chunked streaming copy.
- During copy, SHA-256 is computed over source bytes and stored in receipt events.
- Verification re-hashes staged content before commit.
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

## Camera inventory (user-facing)

The PDF summary reports exact camera inventory facts gathered across all scanned media files:

- files with detected camera metadata
- files without detected camera metadata
- per-label file counts, including `unknown-camera` when metadata is missing

## Camera labels

Folders are named after each camera's model as written in its metadata, which is often an internal code (`SM-A546B`, `FC8482`). RollKeep ships with no built-in list of friendly names. You name your own cameras in the app: **Settings > Camera Labels**.

- **On the current card** lists the cameras found in the scanned source that don't have a label yet. Type a name next to a camera's code and it is saved immediately.
- **Your labels** lists saved labels (edit the name inline, or remove one) and always has an empty row to add a camera that isn't on the card.
- Each row previews the resulting folder, e.g. `Galaxy A54 5G` becomes `galaxy-a54-5g`. Folder names are ASCII, lowercase and kebab-case, so characters outside A-Z and 0-9 are dropped.
- Changes apply to the next scan. Already-imported folders are never renamed. Photos and videos from one camera only land in the same folder if both resolve to the same name, so label a camera once.
- Labels are stored in `~/Library/Application Support/RollKeep/CameraCatalog.json`, a plain `{"SM-A546B": "Galaxy A54 5G"}` file that survives app updates. Only the app writes it; the CLI reads it. If the file becomes unreadable, cameras fall back to their raw codes, the app shows a warning, and a later save keeps the unreadable file as `CameraCatalog.corrupt-<timestamp>.json` instead of overwriting it.
- Set `ROLLKEEP_CAMERA_CATALOG_PATH` to point a run at a different file (the test scripts use this so they never read your real labels).

## Run tests

```bash
swift test
```

## Notes

- `--dry-run` runs scan+plan only and does not execute staging copy.
- The destination path must be writable for primary receipt output; otherwise local temp fallback is used.
