# Performance Audit Findings — Part 2 (2026-07-16)

Continuation of `docs/audits/performance-audit-2026-07-16.md`. That first pass
scoped itself deliberately to the **scan → plan** phase and explicitly deferred
everything downstream and everything added since. This part covers what it
deferred:

- The **copy → verify → commit** phase (`StagingCopyEngine`,
  `StagingCommitEngine`, `IngestPipelinePhases`, `IngestFinalization`) — round 1
  only spot-checked it and said a dedicated pass was needed. This is that pass.
- The **receipt / PDF / logging** pipeline and the **Launcher UI event** hot paths
  — never audited before.
- Code that landed **after** round 1: the JSON camera-model catalog (commit
  `6b61814`), audio ingestion (commit `d864a2c`), and GPR file support (commit
  `0692f5a`).

Like round 1, **this is a documentation-only pass**: findings and
recommendations, no source changes. Every `file:line` citation below was read
directly from source during the audit (three parallel exploration passes, then
direct re-reads of every Tier-1 candidate), not taken from summaries alone.

As in round 1, none of these findings touch the hashing / verification /
durability invariants protected by `docs/adr/0001-no-verification-opt-out.md` or
`docs/testing/red-team-ingest-test-matrix.md`. Where a fast path *would* require weakening
durability, it is called out as explicitly out of scope rather than recommended
(see "Out of scope" below).

## Executive Summary

Eight findings across the three deferred areas, plus one durability cost that is
deliberately **not** a recommendation.

- **Finding A** is the headline: the **commit** phase re-lists the destination
  `Photos`/`Videos` directory from disk **once per committed file**. It is the
  direct twin of round 1's already-shipped Finding 2 — the very same
  `MediaTypeDirectoryResolver`, memoized in the *plan* phase but not the *commit*
  phase — and the same memoization technique applies. Highest value-to-effort item
  here. **Implemented 2026-07-17** — see the Status note under Finding A.
- **Findings B–D** are clean, self-contained regex/formatter hoists on hot
  per-file / per-line paths, each mirroring a caching pattern already present
  elsewhere in the same codebase. Low complexity, behavior-preserving.
- **Findings E–H** are real but lower-leverage or touch a wider surface (the scan
  result model, or the Launcher UI layer) — worth doing, lower priority.
- The copy data path itself audits as **already optimal** (2 physical reads + 1
  write per byte, fused copy+hash, 1 MiB buffers, hash reused in commit dedup).
  Those are recorded under "Confirmed good" so a future audit doesn't re-flag them.

## Priority and Fix-Complexity Legend

Same two-axis tagging as round 1.

**Priority** (impact if left unaddressed):
- `P1`: measurable cost on nearly every ingest; scales with card/batch size, or
  sits on the primary product surface.
- `P2`: real, verified cost, but on a narrower population of files or runs.
- `P3`: correct observation, negligible in practice at realistic data sizes.

**Fix complexity**:
- `Low`: self-contained, local; provably or near-provably behavior-preserving; no
  interface changes.
- `Medium`: mechanical but touches several call sites, or needs care around an
  edge case to avoid changing behavior.
- `High`: needs an actual design decision (caching + invalidation strategy, etc.).

## Findings (Prioritized)

### Tier 1 — clean, high-value, behavior-preserving

#### A. Commit phase re-lists the destination directory once per committed file (`P1` / `Low` — clean)

Status: **IMPLEMENTED 2026-07-17**. Added a local `resolvedParentDirectoryCache:
[String: String]` inside `StagingCommitEngine.commit(files:)`
(`Sources/RollKeepEngine/StagingCommitEngine.swift`), threaded `inout` through
`commitSingle` and `resolveCommitPath`. Because the commit call site holds only
the opaque `plannedFinalPath` string (not the `(mediaType, parentDirectory)` pair
the plan side had as locals — see the "key" note in the recommendation below), the
cache is keyed on the **normalized planned parent directory** and stores the
resolved parent directory; a new `resolveMediaTypeBasePath` helper checks it before
calling `mediaTypeDirectoryResolver.resolvePath(...)` and reconstructs the base path
by appending the untouched filename, so hit and miss are byte-identical. Every file
in a bucket after the first reuses the cached name instead of repeating the
`contentsOfDirectory` disk listing. No interface or signature changes;
`MediaTypeDirectoryResolver` itself is untouched. Regression coverage added:
`testCommitReusesExistingLowercaseMediaDirectoryConsistentlyAcrossManyFilesAndListsBucketOnce`
in `Tests/RollKeepEngineTests/StagingCommitEngineTests.swift`, which commits 16
photos into a pre-existing lowercase `photos/` directory, asserts every file
resolves to the same reused segment, and — via a `contentsOfDirectory`-counting
`FileManager` injected into the engine — asserts the bucket is listed exactly once
for the whole batch (the test lists 16 times, once per file, if the memo is
reverted). Full test suite green (336 tests) after the change.

This is the direct analog of round 1's Finding 2, on the commit side.

- `StagingCommitEngine.resolveCommitPath` calls
  `mediaTypeDirectoryResolver.resolvePath(job.plannedFinalPath)` for **every**
  committed file (`Sources/RollKeepEngine/StagingCommitEngine.swift:275`).
- `resolvePath` walks into `MediaTypeDirectoryResolver.existingDirectoryNameOnFilesystem`
  (`Sources/RollKeepCore/MediaTypeDirectoryResolver.swift:102-123`), which does an
  **uncached** `fileManager.contentsOfDirectory(atPath: parentDirectory.path)`
  (`:103`) plus a `fileManager.fileExists(atPath:isDirectory:)` per
  case-insensitive match (`:115`). This is a full enumeration of the destination
  `Photos` (or `Videos`) parent directory to resolve its casing.
- Because every photo landing in the same date bucket resolves the *same* parent,
  that directory is listed from disk once **per file** instead of once per unique
  directory. Scales per-file × directory size — precisely the large-SD-card import
  the app is built for.

**Why this is a clean fix**: within a single ingest run the answer to "what
directory name should this planned parent use?" cannot change, and the commit loop
is single-threaded. Note the commit loop *does* write to the filesystem during the
run — it `createDirectory`s the final directory (`StagingCommitEngine.swift:198`)
and moves each file in (`:330`), so file N's commit creates the very directory file
N+1 would list. The memo is nonetheless exact because the engine materializes
**precisely** the name resolution returned: on a miss with an empty bucket,
resolution returns canonical `Photos` and the loop then creates `Photos`, so a later
uncached listing would report `Photos` back — identical; on a bucket with an
existing lowercase `photos`, resolution returns `photos` and `createDirectory` is a
no-op — identical. If anything the cache is *more* self-consistent than re-listing:
were an external process to re-case the directory mid-run, the uncached path could
hand two files different casings, while the cache keeps one run internally
consistent.

Note: unlike the plan phase, the commit call passes **no** `knownFilePaths` (the
parameter defaults to empty at `StagingCommitEngine.swift:275`), so the O(N²)
`knownFilePaths` linear scan that Finding 2 also addressed does *not* occur here —
the wasted work in the commit phase is purely the repeated `contentsOfDirectory`
disk listing.

**Recommendation**: memoize the resolved directory across the commit loop, checked
before the `contentsOfDirectory` read — the local-`mediaTypeFolderCache` approach
shipped for Finding 2 in `DestinationPathPlanner.plan()` (commit `0d23778`).
Single-threaded commit means no locking is needed. One structural difference from
the plan side: the commit call site holds only the opaque `plannedFinalPath` string,
not the `(mediaType, parentDirectory)` pair — those are derived *inside*
`resolvePath`. Rather than duplicate that component scan in the engine or widen the
resolver's interface, key the cache on the **normalized planned parent directory**
and cache its resolved counterpart; since `resolvePath` only rewrites the
`<Photos|Videos>` component and appends the filename unchanged, caching
`parent → resolvedParent` and re-appending the filename reproduces its output
exactly. (Consequence: a bucket split across compression subdirs — `Photos/RAW`,
`Photos/Non-RAW` — lists once each rather than once shared, still per-bucket rather
than per-file.)

#### B. Camera-label normalizer compiles NSRegularExpressions on every call (`P2` / `Low`)

- `StripIPhoneLensVariantSuffixRule.apply` compiles up to three patterns per call
  via `.regularExpression`
  (`Sources/RollKeepCore/CameraIdentityLabelNormalizer.swift:64` strip-Apple-prefix,
  `:70` `^iphone\s` test, `:77` `\s+\d{2,3}mm$` strip). At least the first two
  compile even for non-iPhone models before the early return.
- `StripDJIManufacturerPrefixRule.apply` compiles one more per call
  (`CameraIdentityLabelNormalizer.swift:91`, `^\s*dji[\s_-]+(.+?)\s*$`).
- `apply` runs once per rule inside
  `CameraIdentityLabelNormalizer.normalizedModelIdentifier` (`:114-115`), which is
  invoked from `CameraLabeler.infer`. And `infer` runs roughly 2–3× per file
  across a scan (`SourceScanner.swift:236` in the scan loop;
  `SourceScannerModels.swift:305` via `ScanSummary`'s `assessCard`; and again in
  `IngestPreparationService.swift:115`) — so ~8–9 regex compilations per
  model-bearing file. Foundation does not memoize `.regularExpression`
  compilations across calls.

**Recommendation**: hoist each pattern to a `static let NSRegularExpression`,
exactly as `CameraIdentityResolver.opaqueModelCodeRegex` already does in this same
codebase (`Sources/RollKeepCore/CameraIdentityResolver.swift:249-251`). The
`$1`-capture rewrite in `StripDJIManufacturerPrefixRule` maps cleanly to
`stringByReplacingMatches(...withTemplate: "$1")`. Existing coverage in
`Tests/rollkeepTests/CameraIdentityLabelNormalizerTests.swift` guards the
behavior; a hoist must keep it green (identical output).

Note: these two rules **predate** the JSON-catalog commit (`6b61814` only touched
`MapKnownModelCodeToProductNameRule`) — this is a pre-existing cost, not a
regression. The catalog map itself is correctly loaded once
(`CameraModelCatalog.shared`, a `static let`).

#### C. `isOpaqueModelCode` compiles a strip regex per call (`P3` / `Low`)

- `CameraIdentityResolver.isOpaqueModelCode` strips non-alphanumerics with
  `replacingOccurrences(of: #"[^A-Za-z0-9]"#, options: [.regularExpression])` on
  every call (`Sources/RollKeepCore/CameraIdentityResolver.swift:226-230`) — even
  though the very next line (`:236`) already uses the properly-cached static
  `opaqueModelCodeRegex`.
- On the photo-model resolution path
  (`resolvePhotoModel → shouldPreferSupplementalModel → isOpaqueModelCode`), fired
  per photo that has both a primary and a supplemental model.

**Recommendation**: replace the regex strip with a non-regex Unicode-scalar filter
(the character-class is a simple alphanumeric test), or hoist a static regex. Low
impact — only fires when both model fields are present.

#### D. CLI `StructuredLogger` allocates an `ISO8601DateFormatter` per log line (`P2`, CLI-only / `Low`)

- `StructuredLogger.log` constructs a fresh `ISO8601DateFormatter()` inside the
  per-line payload on every call (`Sources/rollkeep/StructuredLogger.swift:33`).
  `ISO8601DateFormatter` is notoriously expensive to allocate (it wraps an
  internal locale/calendar-configured formatter) and is stateless here.
- Only the **CLI** is affected — the Launcher injects `NoopIngestLogger`
  (`Sources/RollKeepEngine/IngestSession.swift:199`), so this never runs in the
  app. In the CLI it fires per erroring scan file
  (`Sources/RollKeepEngine/IngestPipelinePhases.swift:164`), so a card with many
  scan errors pays one allocation per error.

**Recommendation**: hoist to a `static let`, matching the already-hoisted
formatters in `ReceiptWriter` (`ReceiptWriter.swift:86`) and
`PDFReceiptReportBuilder` (`PDFReceiptReportBuilder.swift:158`). Trivial,
fully self-contained.

### Tier 2 — real but lower-leverage or wider surface

#### E. Per-file `createDirectory(withIntermediateDirectories:)` (`P2` / `Low-Medium`)

- Both the copy loop (`Sources/RollKeepEngine/StagingCopyEngine.swift:228`) and the
  commit loop (`Sources/RollKeepEngine/StagingCommitEngine.swift:198`) issue a
  create-directory syscall for the staging/final directory of **every** file, even
  though large batches share a handful of directories. On an existing directory
  it is a no-op, but still a kernel round-trip (internal stat/mkdir attempts).
  Scales per-file.

**Recommendation**: track a `Set<String>` of already-ensured directory paths and
skip the call on a hit. Trivial for the serial commit loop; the copy loop runs
under a bounded-concurrency `OperationQueue`, so its set needs a lock.

#### F. Third `CameraLabeler.infer` pass over the whole card (`P2` amplifier / `Medium`)

- The scan loop already computes `cameraLabeler.infer(for: candidate)` per file
  and accumulates `cameraLabelCounts`
  (`Sources/RollKeepCore/SourceScanner.swift:236-237`).
- But `SourceScanner.scan` constructs `ScanSummary` **without** an override
  (`SourceScanner.swift:286-298`), so `ScanSummary.init` defaults
  `cameraAssessment` to a fresh `CameraLabeler().assessCard(candidates:)`
  (`Sources/RollKeepCore/SourceScannerModels.swift:305`) — re-inferring over the
  entire candidate array and discarding the loop's already-computed result (and
  constructing a throwaway `CameraLabeler`).
- Preparation then infers a third time
  (`Sources/RollKeepCore/IngestPreparationService.swift:115`).

This is the concrete, new-since-round-1 detail behind round 1's Finding 5 note
that `CameraLabeler.infer` is "duplicated." Its per-call cost is *tripled* by
Finding B (each pass re-compiles the strip regexes).

**Recommendation**: pass the scan's already-computed assessment through the
existing `cameraAssessment:` init parameter
(`SourceScannerModels.swift:292`) instead of letting it default to a re-inference.
This touches the scan result model, so it is a real (if small) structural change,
not a one-liner. Much of its value is also recovered simply by doing Finding B
(cheaper per-infer cost).

#### G. `receiptPreviewText` re-joined per receipt line on the main actor (`P2`, Launcher-only / `Low-Medium`)

- `LauncherViewModelReceiptPipeline.appendReceiptLine` appends one line and then
  re-runs `receiptPreviewLines.joined(separator: "\n")`, assigning the whole
  rebuilt string to the `@Published receiptPreviewText`
  (`Sources/rollkeepLauncher/LauncherViewModelReceiptPipeline.swift:157-163`). One
  such event fires per appended receipt line (~3/file during the end-of-copy
  burst), each re-joining up to 240 lines on the main actor.
- The same event path unconditionally rewrites six `@Published` counters via
  `syncProgressCountersToPublished` (`:129-136`) even when nothing changed —
  `@Published` fires `objectWillChange` regardless of equality — while
  `LauncherProgressCounters.apply` already computes a precise `progressChanged`
  bool that is only used for the heartbeat timestamp
  (`Sources/rollkeepLauncher/LauncherProgressStatus.swift:17-67`).

**Recommendation**: keep a rolling preview string (append instead of re-join) or
coalesce/throttle the preview update; gate the counter publishes on the existing
`progressChanged`. Bounded by the 240-line cap, so lower urgency. Launcher-only.

#### H. PDF text renderer rebuilds fonts on every measure/draw (`P3` / `Low`)

- `PDFReceiptTextRenderer.font(size:weight:)` calls `CTFontCreateWithName` and,
  per candidate name, `CTFontCopyPostScriptName` to detect the `.LastResort`
  fallback (`Sources/RollKeepEngine/PDFReceiptRenderingSupport.swift:123-146`).
  It is invoked from both `drawText` (`:44`) and `textWidth` (`:113`), and the
  appendix wrapping calls `textWidth` many times per outcome
  (`PDFReceiptPageComposerSections.swift:251-252`).
- Bounded and on a cold path: the PDF is generated once at finalize and outcomes
  are capped at 80 (`PDFReceiptReportBuilder.swift:225-226`). Pure wasted
  allocation, not a scaling hazard.

**Recommendation**: memoize `CTFont` by `(size, weight)` in a dictionary inside
`PDFReceiptTextRenderer`. Fully self-contained. Lowest priority.

### Out of scope — durability guarantee (updated 2026-11-15: see ADR 0003)

> **Update (2026-11-15):** Superseded by [ADR 0003](../adr/0003-receipt-flush-policy.md).
> `ReceiptWriter` now keeps `write()` immediate per event and flushes at phase
> boundaries, on errors, every 2 seconds during long phases, and with
> `F_FULLFSYNC` on `SESSION_FINISHED`. ADR 0001 covers media verification, not
> receipt flush frequency.

`ReceiptWriter.append` previously performed a `write()` + `fsync(fd)` on **every**
appended event line (`Sources/RollKeepEngine/ReceiptWriter.swift:286`). Each staged-and-
committed file emits roughly 4–6 appends (`fileCopyStarted`,
`fileCopied`, `fileVerifyStarted`, `fileVerified`, `fileCommitStarted`,
`fileCommitted`). On a large batch of small files landing on a slow destination
(SD card / external HDD), these serialized physical flushes could dominate wall
time.

This is the receipt journal's crash-durability contract — every logged event is
written to the OS page cache on return and flushed at phase boundaries and
every 2 seconds, which is what lets the crash-restart recovery path
(`scripts/e2e-crash-restart-recovery.py`) trust the journal. (The *write itself*
is append-only with `O_APPEND`, so there is no O(N²) rewrite to remove — the
cost was the per-line flush, not byte volume.)

### Cross-reference — still-open item from round 1

Round 1's **Finding 3** (video sidecar discovery bypassing the scanner's existing
`siblingURLCache`: `VideoSidecarMetadataExtractor` →
`MediaSidecarSupport.discoverSidecarURLs` falls back to an uncached
`contentsOfDirectory` at `Sources/RollKeepCore/MediaSidecarSupport.swift:64-68`
because the video call path never populates `siblingURLs`) remains **open and
unimplemented**. It is still the cleanest open item carried over from round 1 and
is not re-documented here — see the original doc's Finding 3 for the full trace and
recommended fix. (The scanner's own `SourceScannerSidecarDiscovery` path *does*
pass the cache correctly; the gap is only the AVFoundation-fallback chain.)

## Confirmed good / do not re-flag

Recorded so a future audit does not re-litigate settled ground:

- **Copy phase reads each byte the minimum number of times: 2 reads + 1 write,
  optimal given read-back verification.** Source is read once via raw POSIX
  `read()` and hashed inline in the same loop — no separate hash pass
  (`Sources/RollKeepEngine/StagingCopyEngine.swift:263-296`, hash at `:293`).
  The destination is read once after the atomic rename to verify on-disk bytes
  (`:326`). Commit reuses the copy-phase hash and only hashes *pre-existing*
  destination files, and only on a genuine collision
  (`Sources/RollKeepEngine/StagingCommitEngine.swift:280`) — the common
  no-collision path does zero extra hashing.
- **1 MiB chunk buffers, allocated once outside the loop and reused**
  (`StagingCopyEngine.swift:18,261`; `StagingCommitEngine.swift:15`); the hasher
  consumes them via `withUnsafeBufferPointer` with no copy
  (`StagingCopyEngine.swift:565-571`). Well above the syscall-overhead danger zone.
- **No per-file `fsync` in the copy/commit *data* path** — durability there comes
  from atomic same-volume rename (`moveItem`), not per-file flushes. The only
  fsyncs are the receipt journal (see "Out of scope").
- **No O(N²) receipt rewrite** — `AppendOnlyLineAppender` uses `O_APPEND` and
  writes each NDJSON line incrementally; the file is never re-read or re-serialized
  (`ReceiptWriter.swift:238-290`). Total bytes written is O(content), not O(N²).
- **Summary is a single O(N) pass at finalize** via an O(1) dict lookup, with no
  per-event re-sort of accumulated arrays
  (`Sources/RollKeepEngine/IngestSummaryBuilder.swift:46-101`).
- **Progress events are throttled**: per-byte copy progress to 100 ms / 8 MiB
  (`IngestSession.swift:23-48`, applied at `IngestPipelinePhases.swift:627`); scan
  progress to every 100 files / 0.75 s
  (`Sources/RollKeepCore/SourceScannerProgressSupport.swift:3-24`). High-frequency
  UI updates do not flood the main actor.
- **JSON camera catalog is loaded and parsed exactly once per process** —
  `CameraModelCatalog.shared` is a `static let`
  (`Sources/RollKeepCore/CameraModelCatalogLoader.swift:86`); no per-file re-load.
- **Audio ingestion reuses the scanner's sibling cache** (the companion-pairing
  check at `SourceScanner.swift:165` shares the same `siblingURLCache` as sidecar
  discovery, keyed identically), and audio date parsing uses static formatters
  (`Sources/RollKeepCore/VideoCreationDateParser.swift:33-50`). Audio snapshots are
  correctly reusable across the preview→ingest cache boundary
  (`SourceScanMetadataCache.swift:52`).
- **GPR support is O(1) set membership** — two `Set` literal additions, no new
  per-file work or I/O (`Sources/RollKeepCore/SourceScannerTraversal.swift:254`).
- **`SourceScanMetadataCache` is clean** — `NSLock`-guarded dict keyed by path,
  size+mtime fingerprint validated with no extra I/O, per-mode reusability gated.
- **PDF is generated once at finalize**, with output bounded (file outcomes capped
  at 80, scan errors at 20 — `PDFReceiptReportBuilder.swift:225-228`).
- **`ReceiptWriter.sinkPathHistory` linear scan** — already deemed negligible in
  round 1; not re-flagged.

## Suggested action sequence (for a future fix pass — not this one)

This document makes no code changes. If and when a follow-up fix pass happens:

- **Finding A** (commit directory memoization) — **DONE 2026-07-17**. Was the
  highest value-to-effort item; a direct reuse of the technique shipped for
  Finding 2. See its Status note.

Remaining, in priority order:

1. **Finding B** (hoist normalizer regexes) — high value-to-effort, matches the
   existing `opaqueModelCodeRegex` pattern; guarded by existing tests.
2. **Finding D** (CLI logger formatter) — trivial one-liner.
3. **Finding C** (`isOpaqueModelCode` strip) — trivial.
4. **Finding E** (`createDirectory` dedup).
5. **Finding F** (kill the third `infer` pass) — needs care around the scan model;
   value partly subsumed by Finding B.
6. **Finding G** (Launcher receipt-preview coalescing / counter publish gating).
7. **Finding H** (PDF font memoization) — lowest.

Round 1's **Finding 3** (sidecar sibling cache threading) also remains open and is
still a clean, mechanical win.

## Validation Snapshot

Documentation-only deliverable — no source files modified, so there is no runtime
behavior to validate. What was actually verified this pass:

- Every `file:line` citation above was read directly from source (Tier-1 findings
  re-read line-by-line after the exploration passes), confirming the claimed
  behavior.
- Finding A's "safe to memoize" argument was traced through
  `StagingCommitEngine.resolveCommitPath` → `MediaTypeDirectoryResolver.resolvePath`
  → `existingDirectoryNameOnFilesystem`, and confirmed to be the same resolver
  round 1's Finding 2 memoized on the plan side.
- The three per-call regex sites (Findings B and C) and the per-line formatter
  (Finding D) were each confirmed to lack any existing memoization, and the
  already-cached counterparts (`opaqueModelCodeRegex`, `ReceiptWriter.isoFormatter`,
  `PDFReceiptReportBuilder`'s formatters) confirmed as the pattern to mirror.
- The triple `CameraLabeler.infer` path (Finding F) was confirmed end to end:
  scan-loop infer, discarded `cameraLabelCounts`, `ScanSummary.init`'s defaulting
  `assessCard`, and the prep-time re-infer.
- The durability rationale for leaving `ReceiptWriter`'s per-line `fsync` untouched
  was checked against `docs/adr/0001-no-verification-opt-out.md`.

## Spec Check

Spec source:
- `docs/ROL-6-spec-and-invariants.md`
- `docs/adr/0001-no-verification-opt-out.md`

No spec sections are in conflict. Findings A–H all sit in the pre-copy planning,
post-copy path-resolution, or reporting/UI layers and preserve every verification
and durability guarantee. The one place a speedup would require weakening
durability (per-line receipt `fsync`) is explicitly excluded from the
recommendations for exactly that reason.
