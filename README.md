# rollkeep

`rollkeep` is a Swift command-line tool for media ingest.

Current status: this repository contains the initial CLI skeleton only.

## Implemented functionality

- Swift Package executable: `rollkeep`
- Argument parsing using Apple Swift Argument Parser for:
  - `--source <path>`
  - `--dest <path>`
  - `--dry-run`
  - `--verbose`
  - `--config <path>` (optional placeholder for later implementation)
  - `-h`, `--help`
- Auto-generated usage/help output
- Required argument validation for `--source` and `--dest`
- Dry-run command path that exits successfully (`0`)
- Structured JSON-line logging to stdout

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

## Expected behavior (current)

- `rollkeep --help` prints usage and exits `0`.
- `rollkeep --source ... --dest ... --dry-run` prints a dry-run message and exits `0`.
- Logs are structured JSON lines (`timestamp`, `level`, `message`, `component`, and relevant fields).
- At this stage, the CLI skeleton does not perform scan/copy/verify/commit yet.

## Notes

- Current dry-run behavior validates arguments but does not require the source/destination paths to be mounted or writable yet.
