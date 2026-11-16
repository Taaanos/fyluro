# ST-15: GitHub Actions CI, E2E Quota Assessment, and Public Release Pipeline

**Status:** `open` (assessment needed; waiting on owner decisions Q1 to Q4)
**Raised:** 2026-11-16 · **Type:** Tooling and release workflow
**Related:** [run-e2e-tests.sh](../../../scripts/run-e2e-tests.sh), [package-macos-app.sh](../../../scripts/package-macos-app.sh), [release-app-smoke-test.sh](../../../scripts/release-app-smoke-test.sh), [README.md](../../../README.md).

## Why this story exists

RollKeep will become an open-source project.
External users need proof that public releases match the source code and pass all tests.
Running builds and tests in GitHub Actions provides that proof without an Apple Developer ID or paid membership.

## Quota and E2E heaviness assessment

GitHub Actions pricing depends on repository visibility:

- **Public repository:** Standard GitHub-hosted runners are free with unlimited minutes, including Apple silicon macOS runners.
- **Private repository:** Free accounts get 2,000 standard minutes each month. macOS runners use a 10x multiplier, which equals 200 macOS minutes each month.

[run-e2e-tests.sh](../../../scripts/run-e2e-tests.sh) is heavy for a private quota:

1. It builds both `rollkeep` and `rollkeep-launcher` from source.
2. It checks source-card fixtures with `build-e2e-fixtures.py --check`.
3. It runs all 14 `*e2e*-test.sh` scripts sequentially, including launcher, crash-recovery, fault-injection, and HDD simulations.

Running the full E2E suite on every push while private can exhaust the 200 macOS minutes each month.
We must also check whether all 14 E2E scripts work on a headless GitHub Actions macOS runner (for example, `app-e2e-launcher-test.sh` window checks or external tools like `exiftool`).

## Proposed tiered CI plan

### Tier 1: Pull requests and pushes to `main` (fast check)
- Run `swift test` with SwiftPM build caching (`.build`).
- Run `python3 scripts/build-e2e-fixtures.py --check`.
- Keep runtime short to protect the private macOS quota.

### Tier 2: E2E suite (quota-safe schedule)
- Measure the exact runtime of each `*e2e*-test.sh` script on a GitHub macOS runner.
- While private, run [run-e2e-tests.sh](../../../scripts/run-e2e-tests.sh) only on manual trigger (`workflow_dispatch`) or release tags, or run only a fast subset on pull requests.
- Once public, enable the full E2E suite on pull requests to `main`.

### Tier 3: Release tags (`v*`)
- Run [run-e2e-tests.sh](../../../scripts/run-e2e-tests.sh).
- Build `RollKeep.app`, the `.zip` archive, and the `.sha256` checksum with [package-macos-app.sh](../../../scripts/package-macos-app.sh).
- Run [release-app-smoke-test.sh](../../../scripts/release-app-smoke-test.sh).
- Attach GitHub Artifact Attestations (`actions/attest-build-provenance`) to prove the archive came from the tagged commit.
- Upload the archive and checksum to the GitHub Release without Apple notarization.

## Decisions to confirm before you write workflows

1. **Q1 (Private-repo PR scope):** While private, should pull requests run only `swift test`, or also a small E2E subset (for example, write-audit, symlink-skip, and hostile-filenames)?
2. **Q2 (Quota baseline):** Approve a one-time measurement run on `macos-14` or `macos-15` to record the exact minutes used by `swift test` and each E2E script.
3. **Q3 (Release signing):** Confirm that CI releases stay unsigned (or ad-hoc signed) with Artifact Attestations and Gatekeeper instructions in [README.md](../../../README.md).
4. **Q4 (Headless E2E compatibility):** Decide whether any E2E script that needs a GUI session or missing runner tool should be skipped in CI or adapted.

## Next step

Measure the runtime and runner compatibility of `swift test` and each `*e2e*-test.sh` script, then answer Q1 to Q4.
