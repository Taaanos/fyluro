# rollkeep

`rollkeep` is a Swift command-line tool for media ingest.

Current status: this repository contains the initial CLI skeleton only.

## Implemented functionality

- Swift Package executable: `rollkeep`
- Argument parsing for:
  - `--source <path>`
  - `--dest <path>`
  - `--dry-run`
  - `--verbose`
  - `-h`, `--help`
- Usage/help output
- Required argument validation for `--source` and `--dest`
- Dry-run command path that exits successfully (`0`)

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

## Build and run binary directly

```bash
swift build
./.build/debug/rollkeep --help
./.build/debug/rollkeep --source /Volumes/SD --dest /Volumes/Media --dry-run
```

## Expected behavior (current)

- `rollkeep --help` prints usage and exits `0`.
- `rollkeep --source ... --dest ... --dry-run` prints a dry-run message and exits `0`.
- At this stage, the CLI skeleton does not perform scan/copy/verify/commit yet.

## Notes

- Current dry-run behavior validates arguments but does not require the source/destination paths to be mounted or writable yet.
