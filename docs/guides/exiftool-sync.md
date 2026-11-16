# ExifTool sync procedure (camera-ID oracle)

RollKeep's camera identification ports format facts from ExifTool's camera-identification subset (atom paths, tag IDs, and payload layouts) to native Swift.
ExifTool is the reference implementation and dev-time test oracle.
This guide explains how RollKeep stays in sync with ExifTool.

## Ground rules

- **Do not vendor ExifTool or its test images into this repository.** ExifTool uses the Perl dual license (Artistic License 1.0 or GNU GPL-1.0-or-later). Keep the ExifTool checkout and `t/images` external to keep this repository small and free of Perl dependencies.
- **ExifTool checkout:** Set `ROLLKEEP_EXIFTOOL_CHECKOUT` to your external ExifTool directory. Both `scripts/refresh-exiftool-oracle-snapshot.sh` and the parity tests read this variable.
- **Pinned version:** `13.59`. This version is recorded in `Tests/rollkeepTests/Fixtures/exiftool-oracle-snapshot.json` and checked by `ExifToolOracleParityTests.pinnedExifToolVersion`.

## Setup for contributors

Clone ExifTool at the pinned tag, then set `ROLLKEEP_EXIFTOOL_CHECKOUT` before you run `swift test`:

```bash
git clone --depth 1 --branch 13.59 https://github.com/exiftool/exiftool /path/to/exiftool
ROLLKEEP_EXIFTOOL_CHECKOUT=/path/to/exiftool swift test
```

## The two parity tests

1. **Corpus snapshot (`testCorpusParityAgainstSnapshot`):**
   - Compares RollKeep's make and model output against `Tests/rollkeepTests/Fixtures/exiftool-oracle-snapshot.json` for a subset of `t/images`.
   - Needs no Perl, but still needs `t/images` from the ExifTool checkout on disk.
   - Skips with `XCTSkip` when `t/images` is absent.
   - `knownGaps` lists corpus files that ExifTool identifies and RollKeep does not yet. When RollKeep matches one, the test fails so you remove the entry.

2. **Live fixture parity (`testFixtureLibraryParityAgainstLiveExifTool`):**
   - Local-only test for maintainer fixture libraries.
   - Needs Perl and the repo fixtures under `Tests/TestingDirs` (override with `ROLLKEEP_TESTING_FIXTURES`).
   - Skips with `XCTSkip` when the fixture folder, ExifTool checkout, or `/usr/bin/perl` is absent.
   - Fails only when RollKeep and ExifTool return conflicting identities.

Oracle rules:

- The harness merges ExifTool's identity aliases (`Make`/`DeviceManufacturer`/`AndroidManufacturer`, `Model`/`DeviceModelName`/`AndroidModel`, and serial tags).
- The oracle runs without `-ee`. Timed stream metadata (newer DJI, Insta360 trailer data, Samsung extras) is out of scope, so RollKeep may report extra identities (`oursOnly`).

## When a new ExifTool release lands

1. Check out the target ExifTool release tag in your external checkout (for example, `git -C "$ROLLKEEP_EXIFTOOL_CHECKOUT" fetch --tags && git -C "$ROLLKEEP_EXIFTOOL_CHECKOUT" checkout <tag>`).
2. Read the upstream `Changes` file for camera and video metadata updates.
3. Run `scripts/refresh-exiftool-oracle-snapshot.sh` and inspect the diff in `Tests/rollkeepTests/Fixtures/exiftool-oracle-snapshot.json`.
4. Run `swift test` and review each difference:
   - New camera format to support: update the matching Swift decoder in `Sources/RollKeepCore/` (see `VideoEmbeddedBoxMetadataResolver.swift`, `NativeRAWIdentityFallbackReader.swift`, `M2TSCameraMetadataExtractor.swift`, and per-vendor decoders).
   - Intentional difference (for example, friendlier name over opaque SKU): record it in the test tolerance or `knownGaps` list.
   - Out-of-scope addition (timed metadata or non-camera tags): ignore it.
5. Update `pinnedExifToolVersion` in `Tests/rollkeepTests/ExifToolOracleParityTests.swift`, then commit the snapshot, table updates, and version bump together.
