# ExifTool sync procedure (camera-ID oracle)

RollKeep's camera identification ports the *facts* of exiftool's
camera-identification subset (atom paths, tag IDs, payload layouts) to native
Swift. ExifTool itself is the reference implementation and dev-time test
oracle. This doc records how the two stay in sync.

## Ground rules

- **Never vendor exiftool or its test images into this repo.** ExifTool is
  Artistic/GPL ("same terms as Perl", its README). We port facts, we do not
  translate Perl code. The checkout and its `t/images` corpus stay external.
- Checkout location: `$ROLLKEEP_EXIFTOOL_CHECKOUT` by default; override with
  `ROLLKEEP_EXIFTOOL_CHECKOUT` (used by both the refresh script and the
  parity tests).
- Pinned version: **13.59** — recorded in
  `Tests/rollkeepTests/Fixtures/exiftool-oracle-snapshot.json` and asserted by
  `ExifToolOracleParityTests.pinnedExifToolVersion`.

## The two parity surfaces

1. **Corpus snapshot** (`testCorpusParityAgainstSnapshot`, no perl needed):
   compares RollKeep's resolved make/model against the committed snapshot of
   exiftool's answers over a camera-relevant subset of `t/images`.
   `knownGaps` lists files exiftool identifies and we don't yet, keyed to the
   milestone that closes each; the test fails when a gap silently heals, so
   the list only ratchets forward.
2. **Live fixture parity** (`testFixtureLibraryParityAgainstLiveExifTool`,
   needs perl): runs exiftool over `Tests/TestingDirs`
   videos and fails only on *conflicting* identities; coverage counts are
   printed, not asserted.

Oracle semantics: the harness coalesces exiftool's identity aliases
(`Make`/`DeviceManufacturer`/`AndroidManufacturer`,
`Model`/`DeviceModelName`/`AndroidModel`, plus the serial-number family) —
video identity often hides under the device-tag names (e.g. Sony XAVC XML).
The oracle deliberately runs **without `-ee`**: timed/stream metadata (newer
DJI, Insta360 trailer detail, Samsung phone extras) is out of the port's
scope, so on those files RollKeep's own tiers may legitimately exceed the
oracle ("oursOnly" in the report).

## When a new exiftool release lands

1. Update the checkout (`git -C $ROLLKEEP_EXIFTOOL_CHECKOUT pull` or check out the
   release tag). Skim its `Changes` for camera/video metadata entries — that
   is the list of what upstream learned.
2. Run `scripts/refresh-exiftool-oracle-snapshot.sh` and review the snapshot
   diff: changed entries are exactly where identification behavior moved.
3. Run the parity tests. Three possible outcomes per diff:
   - New camera knowledge we should port → update the relevant Swift decoder
     table (source locations:
     `QuickTime.pm %UserData`, `%Movie` uuid list, vendor `.pm` tables).
   - Upstream changed a value we intentionally differ on → document in the
     test's tolerance/gap lists.
   - Pure additions outside scope (timed metadata, non-camera tags) → ignore.
4. Bump `pinnedExifToolVersion` in `ExifToolOracleParityTests` last, once the
   diffs are dispositioned; commit the snapshot + table changes together.
