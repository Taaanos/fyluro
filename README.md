# RollKeep

RollKeep is a macOS app that copies photos, videos and audio from a camera card to your drive.
It verifies each copy, files each item in a dated folder, and writes a receipt.
The `rollkeep` command-line tool runs the same engine for scripts and terminal use.

- **To use the app:** read the [User Guide](docs/user-guide/README.md).
- **To change the code:** read this file, then `docs/ROL-6-spec-and-invariants.md`.

The app is the main product. The CLI is a complementary interface. It can offer fewer options than the app.

## How it works

Each run follows the same steps:

1. **Scan** the source and plan the destination paths.
2. **Copy** each file to a staging folder in the destination. RollKeep hashes the bytes (SHA-256) while it copies.
3. **Verify** each staged file. RollKeep reads it back and hashes it again. The hash and the byte count must match.
4. **Commit** each verified file to its final path. RollKeep never overwrites a file in the library.
5. **Write a receipt** (NDJSON) that records what RollKeep scanned, copied, verified, skipped or failed.

The ten invariants (I-1 to I-10) are in Section 3 of the spec. They include:

- RollKeep never changes the source card.
- RollKeep never skips verification.
- A failed run keeps its evidence.

## Requirements

- A Mac with Apple silicon and macOS 13 or later.
- Xcode Command Line Tools (Swift 5.9 or later) to build and run unit tests.
- `python3` and `jq` to run the E2E and smoke test scripts (`jq` ships with macOS 15 or later; install it with Homebrew on macOS 13 and 14).
- Full Xcode 26 or later to package `RollKeep.app` with `scripts/package-macos-app.sh` (`xcrun actool` compiles the Icon Composer `.icon` bundle).

## Install

Download the zip from [GitHub Releases](../../releases).
Follow [Install](docs/user-guide/README.md#2-install) in the User Guide. The app is not signed, so macOS blocks the first open.

## Build and run

Run all commands from the repository root.

```bash
swift build                    # debug build of the CLI and the launcher
scripts/run-dev-app.sh         # build a debug RollKeep-dev.app in dist/ and open it
swift run rollkeep-launcher    # run the app executable without an app bundle
swift run rollkeep --help      # show the CLI help
```

## CLI

```bash
swift run rollkeep --source /Volumes/SD --dest /Volumes/Media --dry-run
```

| Option | Purpose |
| --- | --- |
| `--source <path>` | Source folder. If you omit it, RollKeep looks for a card in `/Volumes`. |
| `--dest <path>` | Destination library. If you omit it, RollKeep reuses the last destination that has RollKeep receipts. |
| `--dry-run` | Scan and plan only. RollKeep writes no library files. |
| `--pdf` | Write a PDF summary next to the receipt. |
| `--json` | Print the final summary as JSON. |
| `--verbose` | Print diagnostic logs. |
| `--max-parallel-copies <n>` | Number of files to copy in parallel (default 1). |
| `--detect-timeout-seconds <n>` | Seconds to wait for a card when you omit `--source` (default 60, `0` waits without end). |
| `--pick-source`, `--pick-dest` | Show a folder picker. |

Exit codes: `0` success, `1` other failure, `2` verify, `3` scan, `4` plan, `5` copy, `6` commit, `7` finalize.
The code from `2` to `7` shows the phase that failed.

The CLI always reads your Camera Labels file. The app has a setting for this feature. It is experimental and off by default.

## Where files go

```
<DEST>/YYYY/YYYYMM/<camera>/Photos/<filename>
<DEST>/YYYY/YYYYMM/<camera>/Videos/<filename>
<DEST>/YYYY/YYYYMM/audio/<filename>
<DEST>/_unsorted/...                       (no valid capture date)
<DEST>/_ingest_staging/<SESSION_ID>/...    (temporary; removed after a successful run)
<DEST>/_ingest_receipts/<SESSION_ID>.ndjson
```

The date folder, the camera folder and the RAW split are settings. The full rules are in Section 4 of the spec.
If the destination receipt folder is not writable, RollKeep writes the receipt to `<LOCAL_TMP>/rollkeep/_ingest_receipts/`.

## Test

```bash
swift test                                        # run unit tests
python3 scripts/build-e2e-fixtures.py --synthetic # build tiny synthetic source cards
python3 scripts/build-e2e-fixtures.py --check     # verify source cards against manifest
scripts/run-e2e-tests.sh                          # run all e2e scripts
```

Run `swift test` before you commit.
Run `scripts/run-e2e-tests.sh` before you push to `origin/main`.
On a clean clone, `scripts/run-e2e-tests.sh` creates the synthetic source cards automatically if they do not exist.
You can also build real-media cards locally with `--real` (optional for maintainers).
See `Tests/e2e-ingest-matrix.md` for fixture details.

## Package and release

```bash
scripts/package-macos-app.sh --version <version>   # build dist/RollKeep.app, the zip and the .sha256
scripts/release-cut.sh --bump patch                # test, package, update VERSION and CHANGELOG, publish
```

`release-cut.sh` runs `release-prepare.sh` (tests, packaging, packaged-app smoke test) and then `release-publish.sh` (git tag and GitHub Release).
Every script accepts `-h` and prints its usage. Use `--dry-run` or `--no-publish` to stop before you publish.

Before you ship a release that changes launcher startup, source detection or scan-on-launch code, run this step by hand:

```bash
scripts/release-app-smoke-test.sh --with-launcher-check
```

## Source layout

| Folder | Content |
| --- | --- |
| `Sources/RollKeepCore` | Scan, metadata, camera labels and file rules. |
| `Sources/RollKeepEngine` | The ingest pipeline, receipts and the PDF. The app and the CLI share it. |
| `Sources/rollkeep` | The CLI. |
| `Sources/rollkeepLauncher` | The macOS app. |
| `Tests`, `scripts` | Unit tests, test fixtures, e2e scripts and release scripts. |

## Security and dependencies

- **Zero network and telemetry:** RollKeep makes no network requests and collects no telemetry.
- **Minimal dependencies:** `RollKeepCore` and `RollKeepEngine` have zero external dependencies. The CLI uses only `swift-argument-parser` in [Package.swift](Package.swift).
- **Threat model and reporting:** See [Security Policy](SECURITY.md) and [Security Threat Model](docs/security-threat-model.md).

## Documents

| Document | Use |
| --- | --- |
| [User Guide](docs/user-guide/README.md) | How to use the app. |
| [Docs index](docs/README.md) | Map of all documentation folders. |
| [Spec and invariants](docs/ROL-6-spec-and-invariants.md) | The source of truth for product behavior. |
| [Security Policy](SECURITY.md) | How to report security vulnerabilities privately. |
| [Security Threat Model](docs/security-threat-model.md) | Threat-to-invariant and E2E test mapping. |
| [Contributing](CONTRIBUTING.md) | Pull request checklist and rules. |
| [Working rules](AGENTS.md) | Writing rules, the work loop and the Definition of done. |
| [Work index](docs/work/README.md) | Active bugs and stories quick view. |
| [Bugs](docs/work/bugs.md) | Bugs and gaps that we know about. |
| [Stories](docs/work/stories.md) | Planned features and future work. |
| [Decision records](docs/adr) | Why we made key decisions. |
| [CHANGELOG](CHANGELOG.md) | Changes in each release. |

## License

RollKeep is licensed under the GNU General Public License v3.0. See `LICENSE` for the full text.

See [NOTICE](NOTICE) for third-party notices and ExifTool attribution.

RollKeep is distributed via [GitHub Releases](../../releases) rather than the Mac App Store because Mac App Store terms conflict with GPL-3.0.
