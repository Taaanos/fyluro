# ST-15: GitHub Actions Public Release Pipeline

**Status:** `done` (verified with `workflow_dispatch` on `macos-26`, run `44694313657`)
**Raised:** 2026-11-16 · **Updated:** 2026-11-20 · **Type:** Tooling and release workflow
**Depends on:** [ST-16](synthetic-e2e-fixtures.md) (`done`)
**Related:** [ST-17](../stories.md#st-17-github-actions-ci-and-e2e-test-pipeline) (`parked`), [run-e2e-tests.sh](../../../scripts/run-e2e-tests.sh), [package-macos-app.sh](../../../scripts/package-macos-app.sh), [release-app-smoke-test.sh](../../../scripts/release-app-smoke-test.sh), [release-common.sh](../../../scripts/release-common.sh), [README.md](../../../README.md).

## Why this story exists

RollKeep will become an open-source project.
Public users need proof that each release matches the source code and passes its tests.
GitHub Actions can build, test, attest, and publish releases without an Apple Developer ID.

Note: PR and push CI (`ST-17`) is split out and parked in [stories.md](../stories.md#st-17-github-actions-ci-and-e2e-test-pipeline) while the owner works solo.

## Release workflow design (`release.yml`)

- **Trigger:** `push` on `v*.*.*` tags, plus `workflow_dispatch` for manual runs or re-runs.
- **Runner:** `macos-26` (Apple silicon `arm64`, matching [release-common.sh](../../../scripts/release-common.sh) and Xcode 26 `actool`).
- **Permissions:** `contents: write`, `id-token: write`, `attestations: write`.

### Steps

1. Check out the tagged commit.
2. Verify that [VERSION](../../../VERSION) matches the pushed tag.
3. Run `swift test` and the release-gate E2E checks (see Q1).
4. Build and ad-hoc sign `RollKeep.app`, `.zip`, and `.sha256` with [package-macos-app.sh](../../../scripts/package-macos-app.sh).
5. Verify the packaged bundle with [release-app-smoke-test.sh](../../../scripts/release-app-smoke-test.sh).
6. Attach GitHub Artifact Attestations (`actions/attest-build-provenance`) to the `.zip` archive.
7. Extract the version section from [CHANGELOG.md](../../../CHANGELOG.md) and publish the GitHub Release.

## Signing and Gatekeeper behavior

- [package-macos-app.sh](../../../scripts/package-macos-app.sh) signs the CLI and app bundle ad-hoc (`codesign --force --sign -`) with App Sandbox entitlements.
- `actions/attest-build-provenance` signs a provenance record so users can verify the archive with `gh attestation verify`.
- Without Apple notarization, macOS Gatekeeper blocks the first launch of a downloaded `.zip`.
- [README.md](../../../README.md) must tell users how to clear quarantine (`xattr -cr`) or allow the app in **System Settings > Privacy & Security**.

## Confirmed decisions (2026-11-20)

1. **Q1 (Release gate):** Run `swift test --disable-sandbox`, full [run-e2e-tests.sh](../../../scripts/run-e2e-tests.sh), and [release-app-smoke-test.sh](../../../scripts/release-app-smoke-test.sh) on `macos-15`.
2. **Q2 (Release asset format):** Keep `.zip` and `.sha256` from [package-macos-app.sh](../../../scripts/package-macos-app.sh). Defer `.dmg` unless needed later.
3. **Q3 (Release signing):** Use ad-hoc signing plus `actions/attest-build-provenance`, with Gatekeeper instructions in [README.md](../../../README.md).

## Next step

Tag a release (`v*.*.*`) when ready to publish the first GitHub Actions release with Artifact Attestations.
