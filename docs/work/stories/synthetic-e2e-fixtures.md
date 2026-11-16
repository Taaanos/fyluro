# ST-16: Clean-Clone Synthetic E2E Fixtures for Public Contributors and CI

**Status:** `done` (2026-11-16)
**Raised:** 2026-11-16 · **Type:** Tooling and test fixtures
**Blocks:** [ST-15](github-actions-ci.md)
**Related:** [build-e2e-fixtures.py](../../../scripts/build-e2e-fixtures.py), [run-e2e-tests.sh](../../../scripts/run-e2e-tests.sh), [fixture-manifest.json](../../../Tests/TestingDirs/fixture-manifest.json), [README.md](../../../README.md), [CONTRIBUTING.md](../../../CONTRIBUTING.md).

## Why this story exists

Unit tests via `swift test` pass on a clean clone because fixture-dependent tests call `XCTSkip`.
However, [run-e2e-tests.sh](../../../scripts/run-e2e-tests.sh) and [build-e2e-fixtures.py](../../../scripts/build-e2e-fixtures.py) required `Tests/TestingDirs/SD_CARD1` and `Tests/TestingDirs/SD_CARD2`.
These folders are gitignored (about 1.8 GB) and came from a private local directory.
On a clean clone or a GitHub Actions runner ([ST-15](github-actions-ci.md)), `build-e2e-fixtures.py --check` and all E2E scripts failed.

## Owner decisions (2026-11-16)

1. **Q1 (Fixture strategy):** Option A. Add `--synthetic` mode (also the default) in [build-e2e-fixtures.py](../../../scripts/build-e2e-fixtures.py) to build tiny `SD_CARD1` and `SD_CARD2` trees. Keep `--real` as an optional maintainer mode.
2. **Q2 (Manifest policy):** Track synthetic cards in [fixture-manifest.json](../../../Tests/TestingDirs/fixture-manifest.json). Use gitignored `Tests/TestingDirs/fixture-manifest.real.json` for optional `--real` builds.
3. **Q3 (Docs update):** Update [README.md](../../../README.md), [CONTRIBUTING.md](../../../CONTRIBUTING.md), and [e2e-ingest-matrix.md](../../../Tests/e2e-ingest-matrix.md) so contributors can run the E2E suite on a clean clone.

## Implementation summary

- Added deterministic pure-Python builders in [build-e2e-fixtures.py](../../../scripts/build-e2e-fixtures.py) for all 43 files (`SD_CARD1`: 11 files, 4.3 KB; `SD_CARD2`: 32 files, 9.6 KB).
- Synthetic files use valid HEIC, JPEG, PNG, TIFF/RAW, CR2, QuickTime MOV, M4A, MP4 (GoPro GPMF, DJI Xtra, Samsung smta, Sony NonRealTimeMeta), Insta360 INSV, WAV, SRT, and XML structures with embedded metadata.
- Updated [run-e2e-tests.sh](../../../scripts/run-e2e-tests.sh) to build synthetic cards automatically when `SD_CARD1` or `SD_CARD2` is absent, then verify with `--check`.
- Updated [fixture-manifest.json](../../../Tests/TestingDirs/fixture-manifest.json) to track the synthetic cards.
- Updated [README.md](../../../README.md), [CONTRIBUTING.md](../../../CONTRIBUTING.md), and [e2e-ingest-matrix.md](../../../Tests/e2e-ingest-matrix.md).
