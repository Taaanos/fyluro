# Performance Audit Findings (2026-07-16)

Scope reviewed:
- Scan → plan phase hot paths: source scanning, sidecar discovery, embedded video
  metadata parsing, AVFoundation metadata extraction, destination path planning
- Repeated/redundant work across a batch ingest (many files sharing a directory,
  camera, or metadata shape)
- Brute-force patterns (linear scans, uncached lookups) where a structured
  alternative (memoization, an existing cache) is already available or easy to add

Not deeply re-audited in this pass (spot-checked only): the copy → verify → commit
phase (`StagingCopyEngine`, `StagingCommitEngine`). It already uses bounded
parallel `OperationQueue` copying with streaming SHA-256, which looks like an
appropriate design for that phase; a dedicated pass would be needed to make any
stronger claim about it.

**Everything below lives in the scan/plan phase, upstream of staging and
verification.** None of these findings touch the hashing/verification safety
invariants covered by `docs/red-team-ingest-test-matrix.md` or
`docs/adr/0001-no-verification-opt-out.md` — this is about wasted CPU/I/O before
any copy begins, not about weakening any correctness or safety guarantee.

This is a documentation-only pass: findings and recommendations, no source
changes. See "Suggested action sequence" at the end for a proposed order to fix
things later.

## Executive Summary

Five findings, two of which are ready-to-implement-whenever-you-want clean wins:

- **Finding 2** (destination path planner, O(N²) per-file directory resolution)
  and **Finding 3** (sidecar discovery bypassing an existing cache) are both
  low/low-medium complexity to fix, provably or near-provably behavior-preserving,
  and don't require any new abstractions. **Finding 2 implemented 2026-07-16**
  — see the Status note under Finding 2.
- **Finding 1** (the Launcher previews an entire source card, then re-scans it
  fully a second time on actual import) is the highest-impact item found — it
  affects the primary product surface (the macOS app) on every single ingest.
  A concrete caching design was worked out during this audit (see below) and is
  provably correct for the common case. **Implemented 2026-07-16** — see the
  Status note under Finding 1 for the shipped design and measured results.
- **Finding 4** (a redundant regex re-scan in the embedded video metadata parser)
  is real but touches `NSRange`/UTF-16 index math in a file that has previously
  shipped a length-unbounded-input bug (`RT-P1-10`). Worth fixing eventually, but
  only with dedicated before/after test coverage.
- **Finding 5** bundles several minor, low-real-world-impact observations that are
  correct but not worth individual action given realistic data sizes.

## Priority and Fix-Complexity Legend

Each finding gets two independent tags:

**Priority** (impact if left unaddressed):
- `P1`: measurable cost on every, or nearly every, ingest; scales with card/batch size, or sits on the primary product surface
- `P2`: real, verified cost, but on a narrower population of files or runs
- `P3`: correct observation, but negligible in practice at realistic data sizes

**Fix complexity** (how clean a fix would be — this is the axis the user asked this audit to prioritize):
- `Low`: self-contained, local change; provably or near-provably behavior-preserving; no interface/signature changes
- `Medium`: mechanical but touches several call sites, or needs care around an edge case (e.g. Unicode/index math) to avoid changing behavior
- `High`: needs an actual design decision (e.g. a caching + invalidation strategy) — not a quick edit no matter how it's written

## Findings (Prioritized)

### 1. Preview scan and the real ingest scan independently run the full metadata pipeline (`P1` priority / `High` fix complexity)

Status: **IMPLEMENTED 2026-07-16**. The caching design below was built as
specified: `Sources/RollKeepCore/SourceScanMetadataCache.swift` adds
`InMemorySourceScanMetadataCache`, consulted and populated inside
`SourceScanner.scan(...)`'s per-file loop and threaded through
`IngestPreparationService`, `IngestSession`, and the Launcher's preview scan.
A known-camera file resolved during preview is reused outright at ingest
start instead of being re-opened and re-parsed; an unknown-camera file (or
one whose size/mtime changed since preview) is still fully reassessed. Local
benchmark against real fixtures
(`Tests/rollkeepTests/SourceScanMetadataCacheBenchmarkTests.swift`): a
7-file known-camera batch spanning GoPro/DJI/Sony/Apple formats went from a
191ms cold `.deep` scan to a 1.3ms cache-warmed one; the preview pass itself
showed no measurable regression (165ms → 170ms). Correctness coverage in
`Tests/rollkeepTests/SourceScannerMetadataCacheTests.swift`, including a
regression test for a bug found during design review (a cache hit would have
silently defeated the `forcedMissingCaptureDateRelativePaths` E2E test hook
if left unguarded).

The macOS Launcher (the primary product surface) scans the entire source card
twice, fully independently, for a normal import:

- Evidence (preview pass): `Sources/rollkeepLauncher/LauncherViewModelActions.swift:238-258` runs `sourceScanner.scan(sourcePath:mode: .preview)` on a background task the moment a valid source path is set, to drive the live "N photos, M videos, X GB" UI.
- Evidence (real pass): `Sources/RollKeepEngine/IngestPipelinePhases.swift` → `IngestPreparationService.prepare()` runs an entirely separate `.deep` scan over the same tree when the user clicks "Start Import."
- Nothing computed during the preview pass (AVFoundation metadata, box-walked vendor metadata, sidecar discovery results) is cached or reused by the real pass.

**Nuance found during verification** (this lowers the finding from what a first read
suggests): this is not a clean 2x on the most expensive tier. `AVFoundationVideoMetadataExtractor.EmbeddedFallbackMode` (`Sources/RollKeepCore/AVFoundationVideoMetadataExtractor.swift:6-23`) already distinguishes `.structuredOnly` (box-walk vendor-atom decode only, "single-digit milliseconds" per its own doc comment) from `.full` (adds the blind byte-scan text parser, `EmbeddedVideoMetadataTextParser`, which is the most expensive fallback tier). Preview mode already uses `.structuredOnly`, sparing that specific cost.

What is **not** spared and runs twice in full regardless of mode:
- AVFoundation's own container metadata query (`asset.commonMetadata`, `asset.metadata(forFormat:)`) — likely the single most expensive per-file step for video, since it requires opening/parsing the container.
- Sidecar file discovery (`MediaSidecarSupport.discoverSidecarURLs`) and, where triggered, sidecar metadata parsing.
- Photo EXIF extraction via ImageIO.

**Risk**: every GUI ingest pays for a full first pass (to populate the live preview) and then a full second pass (to actually plan the import), with no work carried over, on the app's primary surface. This is inherent to what preview is *for* — it deliberately does real, ingest-shaped work (metadata resolution, camera identification) early so the user sees accurate live stats before committing to an import. That's a legitimate product goal; the problem is only that none of that work is kept.

**Proposed design (worked out 2026-07-16)**: split on whether a file's camera identity was resolved without needing the one genuinely mode-dependent tier.

- **Core idea**: cache every file's resolved metadata snapshot during the preview pass. At ingest start, reuse the cached snapshot outright for any file whose camera came back known (`cameraLabel != CameraLabeler.unknownLabel`); files that came back unknown get fully reassessed by the real (`.full`) scan, since that's precisely the population that needs the deeper tier preview never attempted.
- **Why this split is exact, not just a good heuristic**: `VideoMetadataFallbackResolver.requiresEmbeddedFallback` (`Sources/RollKeepCore/VideoMetadataFallbackResolver.swift:62-65`) only invokes the blind byte-scan text parser when `cameraMake == nil && cameraModel == nil` — and that text parser is the *only* tier that differs between preview (`.structuredOnly`, stubbed to nil) and deep (`.full`, actually runs). AVFoundation's primary metadata, the sidecar fallback tier, and the box-walk vendor-atom decode tier all run identically regardless of mode. So for any file where preview resolved a known camera label, the deep pass is mathematically guaranteed to reach the same tiers and produce the identical result — this isn't an approximation, it's provable from the gating logic itself.
- **Cache the whole snapshot, not just the label**: `AVFoundationVideoMetadataExtractor.extractMetadata` (`Sources/RollKeepCore/AVFoundationVideoMetadataExtractor.swift:141-165`) extracts capture date and camera make/model/serial from the same single AVAsset load. Caching only "camera model" would throw away the part that's actually expensive to reproduce (reopening the container) while still needing a second reopen for the date.
- **Photos don't need the known/unknown split at all**: `ImageIOPhotoMetadataExtractor` has no mode parameter anywhere — it does identical work regardless of preview/deep. Every photo result from preview is safely reusable unconditionally, known camera or not.
- **Synergy with Finding 3**: a cache hit means the sidecar directory was already listed during preview and doesn't need re-listing at ingest start — this design delivers most of Finding 3's benefit for free, for the "known camera" population. Finding 3's own fix still matters for CLI runs (no preview pass exists there at all) and for the unknown-camera reassessment bucket.
- **Staleness guard**: key the cache by path, store size + mtime alongside the cached snapshot (already available on every `MediaCandidate`, no new I/O needed), and treat a fingerprint mismatch at ingest-start as a cache miss — falls through to full resolution. Covers the case where files changed, or a different card got mounted at the same path, in the gap between preview and clicking start.
- **A trade-off worth naming, not chasing**: a file can have an unknown camera but a *resolved* capture date (`requiresSidecarFallback` triggers on any nil field among date/make/model/serial, not camera fields specifically) — under this design that file's date gets redundantly (but correctly) re-derived during reassessment. A more precise design could cache camera-eligibility and date-eligibility independently per field, but that adds real complexity for a small marginal gain against the stated goal of clean, non-complex wins. Recommendation: accept this trade-off and keep the simpler binary split.
- **Expected cost on the preview side**: preview already resolves this same per-file data today in order to compute the live camera-distribution stats — it just discards the per-file result after folding it into aggregate counts. Retaining it (plus the already-available size/mtime fingerprint) should be close to compute-neutral: no new file I/O, no new AVFoundation/ImageIO calls, just keeping a value that was already computed. The realized win is almost entirely on the ingest-start side: skipping the AVFoundation container reopen, sidecar directory listing, and box-walk vendor-atom decode for every file that already resolved a known camera during preview.
- **Scope**: this only ever applies to the Launcher — the CLI has no preview pass, so it's unaffected either way. The cache-consulting logic (given a path + fingerprint + prior snapshot, decide reuse-or-reassess) should live in `RollKeepCore` for testability; populating and handing off the cache across the preview→start transition is Launcher-specific plumbing (`LauncherViewModelActions.swift`'s scan task, and `IngestPipelinePhases.swift`'s prepare call).
- **What doesn't exist yet**: today's `LauncherSourceScopeSummary`/`lastPreviewSummary` (`Sources/rollkeepLauncher/LauncherSourceScanning.swift:4-26`) only retains aggregate counts and camera-label distribution, not per-file data — so this cache is new state, not something to wire up from existing infrastructure.

**Recommendation**: the design above is sound and worth implementing as its own future pass — it's no longer an open question, but it is still new state, async/cancellation-safe plumbing across the preview→start boundary, and a cross-cutting change (Launcher + RollKeepCore), so it stays out of scope for a "clean quick wins" bundle alongside Findings 2/3.

### 2. `DestinationPathPlanner` / `MediaTypeDirectoryResolver`: O(N²) per-file directory resolution (`P1` priority / `Low` fix complexity — clean)

Status: **IMPLEMENTED 2026-07-16**. Added a local `mediaTypeFolderCache:
[String: String]` inside `DestinationPathPlanner.plan()`
(`Sources/RollKeepCore/DestinationPathPlanner.swift`), keyed by
`(mediaType.rawValue, parentDirectory.path)`. The per-file loop now checks
this cache before calling `mediaTypeDirectoryResolver.directoryName(...)`;
on a miss it resolves once (the one disk listing + known-paths scan) and
memoizes the result, so every subsequent file in the same date/camera bucket
reuses it instead of repeating the filesystem read and the linear
`knownFilePaths` scan. No interface or signature changes;
`MediaTypeDirectoryResolver` itself is untouched. Regression coverage added:
`testPlanReusesExistingDirectoryNameConsistentlyAcrossManyFilesInBucket` in
`Tests/rollkeepTests/DestinationPathPlannerTests.swift`, which plans a dozen
photos into a pre-existing lowercase `photos/` directory and asserts every
file (not just the first) resolves to the same reused segment. Full test
suite green (335 tests) after the change.

- Evidence: `Sources/RollKeepCore/DestinationPathPlanner.swift:97-101` rebuilds `Array(occupiedByHash.keys)` from a dictionary that gains one entry per planned file (`DestinationPathPlanner.swift:145-146`), on *every* iteration of the per-file loop, then passes that freshly rebuilt array into `mediaTypeDirectoryResolver.directoryName(...)`.
- Inside `MediaTypeDirectoryResolver.existingDirectoryName` (`Sources/RollKeepCore/MediaTypeDirectoryResolver.swift:58-100`):
  - It first does an **uncached** `fileManager.contentsOfDirectory(atPath:)` disk read per file (`existingDirectoryNameOnFilesystem`, lines 102-123) — even when many files in the same batch share the exact same parent folder (same capture date + camera), that folder gets listed from disk once per file landing in it, instead of once per unique folder.
  - If nothing is found on disk, it falls through to a `.compactMap` linear scan of the *entire* `knownFilePaths` array (lines 67-94), doing URL construction and string comparisons per entry, to see whether any already-planned file in this batch established a (possibly non-canonical, e.g. lowercase `"photos"`) directory name for this exact parent. Since this array grows every iteration, this is an O(N) scan run N times — O(N²) overall for a large card import.

**Why this is a clean fix**: the answer to "what directory name should this (parentDirectory, mediaType) pair use?" cannot change across files within a single `plan()` call. The filesystem doesn't change mid-plan (this all runs before any copy/write), and `existingFinalFiles` — the only source of "prior library state" — is fully loaded into `occupiedByHash` before the per-file loop even starts (`DestinationPathPlanner.swift:74-83`). Any two files that map to the same `(parentDirectory, mediaType)` are provably going to get the same resolved directory name, whether resolved on file #3 or file #300. That makes this safe to memoize with a local `[String: String]` cache keyed by `(parentDirectory.path, mediaType)` inside `plan()`'s loop, checked before calling into the resolver — no interface changes, no new types, no behavior change.

**Risk**: this scales specifically with the thing the app is built for — large SD-card imports with hundreds to thousands of files. Small test fixtures (10-29 files, per `docs/red-team-ingest-test-matrix.md`) will never surface this in practice; a multi-thousand-file card import would.

**Recommendation**: add a local memoization cache inside `plan()`, keyed by `(parentDirectory.path, mediaType)`, checked before calling `mediaTypeDirectoryResolver.directoryName(...)`.

### 3. Sidecar directory listing bypasses the scanner's existing sibling cache (`P2` priority / `Low-Medium` fix complexity)

- Evidence: `SourceScanner.swift:46` already declares `siblingURLCache: [String: [URL]]`, threaded through `SourceScannerSidecarDiscovery.swift:20-38`, specifically built to avoid repeated `contentsOfDirectory` calls per directory during the scan.
- But `VideoSidecarMetadataExtractor.extract()` (`Sources/RollKeepCore/VideoSidecarMetadataExtractor.swift:11`) calls `MediaSidecarSupport.discoverSidecarURLs(for: videoURL)` with no `siblingURLs` argument, so `MediaSidecarSupport.swift:64-68` always falls back to its own fresh, uncached `contentsOfDirectory` disk read — every time a video reaches the sidecar-fallback tier (i.e. AVFoundation's own metadata didn't resolve make/model/serial/date).
- This duplicates a listing the scanner already did (or will do) for that same directory. Any folder with multiple clips missing full AVFoundation metadata — common for action cameras — re-lists that folder from disk once per clip instead of once.

**Fix complexity note**: the call chain from where the cache lives to where it's needed is `AVFoundationVideoMetadataExtractor` (two closures, `Sources/RollKeepCore/AVFoundationVideoMetadataExtractor.swift:26-77`) → `VideoMetadataFallbackResolver` → `VideoSidecarMetadataExtractor` → `MediaSidecarSupport`. Reusing the existing cache means threading a parameter through roughly five layers — mechanical, no new abstractions needed, but a wider diff than Finding 2.

**Recommendation**: thread the scanner's existing sibling listing (or the cache itself) down to `discoverSidecarURLs`'s `siblingURLs` parameter — which already exists on the function signature specifically for this purpose (`MediaSidecarSupport.swift:58`) and is simply never populated by this call path today.

### 4. Embedded video metadata parser re-scans the same text prefix (`P2` priority / `Medium` fix complexity)

- Evidence: `Sources/RollKeepCore/EmbeddedVideoMetadataTextParser.swift:69-89`. The parser first scans `rawText` for creation date, make, model, and serial. If any of those are still `nil` afterward, it builds `combinedText = rawText + "\n" + printableStrings.joined(separator: "\n")` (via `searchableText()`, lines 41-52) and re-runs the *same* ~10 regexes over `combinedText` for whichever fields are still missing.
- Because `combinedText`'s prefix is byte-identical to `rawText`, and `NSRegularExpression` matching is deterministic, the first `len(rawText)` characters are necessarily re-scanned by the second pass for a result already known to be negative from the first pass. The only part of `combinedText` that can actually produce a new match is the appended `printableStrings` suffix.
- This is bounded (rawText is capped by the `byteCount` search window, 2MB by default for videos, `EmbeddedVideoMetadataTextParser.swift:7`), so it's a bounded, not unbounded, cost — but it's still a full second regex battery over data whose answer for that portion is already known.

**Why this isn't a slam-dunk fix**: restricting the second pass to only the appended suffix requires exact `NSRange`/UTF-16 index arithmetic around the `"\n"` join point, and this is the exact file where `RT-P1-10` (an unbounded-length embedded-metadata string that could abort a whole ingest run) was found and fixed. A change here should not be made casually — it needs explicit before/after test coverage proving identical results, not just a quick edit.

**Recommendation**: document precisely (done here); only implement with dedicated test coverage confirming identical output pre/post, given this file's track record.

### 5. Minor / low-impact observations (`P3` priority, bundled)

These are correct observations from direct code reading, but none are worth
individual action given realistic data sizes:

- `Sources/RollKeepCore/AVFoundationVideoMetadataExtractor.swift:157-165` re-queries `asset.metadata(forFormat:)` once per metadata namespace a file exposes, and `consumeMetadataItems`/`isMakeItem`/`isModelItem`/`isSerialItem`/`keyContainsAny` (lines 197-271) do several `.lowercased()`/`.contains` string checks per item. This is inherent to AVFoundation's metadata API shape — low actionability without a different extraction approach entirely.
- The same file's embedded-fallback path (`VideoEmbeddedBoxMetadataResolver`) re-parses the ISO-BMFF box structure from scratch for a file AVFoundation already opened and parsed internally. This is architecturally inherent — AVFoundation doesn't expose raw box trees — and not fixable without either dropping the custom box walker (losing vendor-specific metadata AVFoundation doesn't surface) or a much larger rewrite. Not recommended.
- `CameraLabeler.infer(for:)` is computed once during scanning (`Sources/RollKeepCore/SourceScanner.swift:173`) and again during preparation (`Sources/RollKeepCore/IngestPreparationService.swift:114`) for every candidate. It's a cheap pure heuristic (no I/O), so the aggregate cost is small, but it is genuinely duplicated work. De-duping it would mean threading the first result through `MediaCandidate`/`ScanSummary`, which is a real (if small) structural change, not a one-line fix.
- `MediaSidecarSupport.swift:145-147` (`metadataPriorityIndex`) does a linear scan of a fixed 10-element array per comparison inside `.sorted(by:)`. Trivial at real-world sidecar counts (under 10 per file). Verified directly.
- `firstChild` (`Sources/RollKeepCore/ISOBMFFBoxWalker.swift:87`), called from `VideoEmbeddedBoxMetadataResolver.swift:73,82,160,170`, does linear scans, but always over top-level box arrays that are small in practice. Verified directly.
- `Sources/RollKeepEngine/ReceiptWriter.swift:228` (`sinkPathHistory.contains`) is a linear scan, but the list only ever holds a couple of entries across a whole ingest run (receipt sink fallback retries). Verified directly.

## Suggested action sequence (for a future fix pass — not this one)

This document makes no code changes. If and when a follow-up fix pass happens, this is the suggested order:

1. **Finding 2** (planner O(N²)) — highest value-to-effort ratio, fully clean, provably behavior-preserving. **Implemented 2026-07-16.**
2. **Finding 3** (sidecar cache threading) — still clean, more mechanical surface to touch.
3. **Finding 4** (regex re-scan) — only with dedicated Unicode/NSRange edge-case test coverage given this file's history.
4. **Finding 1** (preview/deep duplication) — **implemented 2026-07-16**, see the Status note under Finding 1.

Finding 5's items are not recommended for action; they're included for completeness.

## Validation Snapshot

This is a documentation-only deliverable — no source files were modified, so there
is no runtime behavior to validate. What was actually verified in this session:

- Every file:line citation above was read directly from source (not taken solely
  from initial exploratory sub-agent summaries) to confirm the claimed behavior.
- The determinism argument behind Finding 2's "safe to memoize" claim was traced
  through `DestinationPathPlanner.plan()` end to end.
- The severity of Finding 1 was revised downward from an initial "full duplicate
  cost" read after finding `AVFoundationVideoMetadataExtractor.EmbeddedFallbackMode`
  already mitigates the most expensive fallback tier for preview scans.
- `Sources/RollKeepCore/MediaSidecarSupport.swift:145-147`, `ISOBMFFBoxWalker.swift:87`
  usage sites, and `ReceiptWriter.swift:228` were independently grep-confirmed.

## Spec Check

Spec source:
- `docs/ROL-6-spec-and-invariants.md`
- `docs/adr/0001-no-verification-opt-out.md` (explicitly rejects speed-vs-safety
  tradeoffs — cited here because every recommendation in this document is scoped
  to the pre-copy scan/plan phase and does not touch verification)

No spec sections are in conflict: all findings sit upstream of the verification
and commit invariants that ADR 0001 and the red-team matrix protect.
