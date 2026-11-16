# ST-16: Clean-Clone Synthetic E2E Fixtures for Public Contributors and CI

**Status:** `open` (waiting on owner decisions Q1 to Q3)
**Raised:** 2026-11-16 · **Type:** Tooling and test fixtures
**Blocks:** [ST-15](github-actions-ci.md)
**Related:** [build-e2e-fixtures.py](../../../scripts/build-e2e-fixtures.py), [run-e2e-tests.sh](../../../scripts/run-e2e-tests.sh), [fixture-manifest.json](../../../Tests/TestingDirs/fixture-manifest.json), [README.md](../../../README.md), [CONTRIBUTING.md](../../../CONTRIBUTING.md).

## Why this story exists

Unit tests via `swift test` pass on a clean clone because fixture-dependent tests call `XCTSkip`.
However, [run-e2e-tests.sh](../../../scripts/run-e2e-tests.sh) and [build-e2e-fixtures.py](../../../scripts/build-e2e-fixtures.py) require `Tests/TestingDirs/SD_CARD1` and `Tests/TestingDirs/SD_CARD2`.
These folders are gitignored (about 1.8 GB) and come from a private local directory (`Tests/TestingDirs`).
On a clean clone or a GitHub Actions runner ([ST-15](github-actions-ci.md)), `build-e2e-fixtures.py --check` and all E2E scripts fail.

## Options

### Option A: Add a synthetic fixture generator for clean clones and CI
- Add a `--synthetic` mode in [build-e2e-fixtures.py](../../../scripts/build-e2e-fixtures.py) (or a dedicated script) that builds tiny `SD_CARD1` and `SD_CARD2` trees.
- Include minimal valid EXIF, QuickTime, audio, and XML sidecar files that satisfy the E2E assertions.
- Keep the private real-media set as an optional maintainer check.

### Option B: Separate self-contained E2E scripts from local-fixture E2E scripts
- Update security and fault E2E scripts to generate tiny temporary files instead of cloning `SD_CARD1`.
- Skip or gate the full `SD_CARD1` and `SD_CARD2` matrix scripts when local fixtures are absent.
- Update [README.md](../../../README.md) and [CONTRIBUTING.md](../../../CONTRIBUTING.md) to explain this behavior.

### Option C: Commit tiny synthetic `SD_CARD1` and `SD_CARD2` trees directly
- Replace the gitignored 1.8 GB cards with tracked synthetic files under 1 MB total.
- Move the 1.8 GB real-media sweep to an opt-in maintainer script.

## Decisions to confirm before you write code

1. **Q1 (Fixture strategy):** Choose Option A, Option B, or Option C.
2. **Q2 (Manifest policy):** Decide whether [fixture-manifest.json](../../../Tests/TestingDirs/fixture-manifest.json) tracks synthetic cards or uses a separate manifest for real media.
3. **Q3 (Docs update):** Update [README.md](../../../README.md) and [CONTRIBUTING.md](../../../CONTRIBUTING.md) so contributors know how to run the E2E suite on a clean clone.

## Next step

Answer Q1 to Q3 before starting [ST-15](github-actions-ci.md).
