# ADR 0001: No Opt-Out for Post-Copy Verification, No Incremental Skip Based on Persisted State

Date: 2026-07-13
Status: Accepted

## Context

Some users running repeated ingests from the same card (offloading daily without
emptying the card between shoots) perceive RollKeep as slow, because every run
re-copies and re-verifies files that were already ingested in a prior run. This
reads as a "sync" workflow to the user, but RollKeep currently treats every run
as a full ingest.

Two ways to address the perceived slowness were considered and rejected:

### Option A: User-facing opt-out to skip post-copy verification

RollKeep's post-copy verification rereads the staged file after the atomic
rename into staging and rehashes it (SHA-256, `StagingCopyEngine.swift`),
comparing against the hash captured while writing. (Corrected 2026-10-04: this
text said "destination file"; the code verifies the staged file before commit.) This is the mechanism that catches silent
bit-level corruption on removable/flash media — a bad sector or controller bug
that returns the wrong bytes at the same length, with no error surfaced by the
OS. This failure mode is real and specific to the flash media RollKeep's users
ingest from, not a hypothetical.

Verification cost is I/O-bound (a second full read of the destination), not
CPU-bound — swapping SHA-256 for a lighter hash algorithm would not
meaningfully change run time, since hashing is far faster than the storage
media being read. There is no cheap version of this check.

Letting users disable verification for speed would remove the one guarantee
the product exists to make, in exchange for a saving that doesn't actually
come from the hash algorithm being "too strong" — it comes from unavoidable
I/O. This conflicts with RollKeep being an opinionated, safety-first tool with
a minimal, non-negotiable feature surface.

### Option B: Incremental sync via persisted ledger/manifest

Considered recording `{path, size, mtime, hash}` for each file at the time it's
first ingested and verified, then on subsequent runs using cheap `stat()` calls
(size + mtime) to detect already-ingested, unchanged files and skip them
without any content I/O.

This does reduce work for already-verified files, but only by trusting stored
state instead of the file's current bytes. Any ledger — whether kept as
app-internal state or as a self-describing manifest sidecar living in the
destination folder — reflects what RollKeep *did*, not what is *currently
true* on disk. If the destination changes outside RollKeep's knowledge (drive
reformatted, mounted and edited elsewhere, bit rot after the last check), the
ledger goes stale and RollKeep would silently skip verifying a file that no
longer matches what it believes. Confirming the ledger is still accurate would
require rereading and rehashing the destination anyway — the exact I/O cost
the ledger was meant to avoid.

This is a fundamental tradeoff, not an engineering gap to close: any
skip-by-remembered-state design reopens a trust gap proportional to how long
it's been since the last real check.

## Decision

- Post-copy verification (full destination reread + hash compare) remains
  mandatory on every copied file, with no user-facing setting to disable or
  weaken it.
- RollKeep will not implement incremental/ledger-based skip-if-unchanged
  logic. Every ingest run re-verifies everything it copies; there is no
  persisted state used to bypass content verification for files believed to
  already be correct.

## Why

- The corruption mode verification catches (silent, same-length bit
  corruption on flash media) is central to why users trust RollKeep with
  irreplaceable camera media. Removing or weakening it undermines the
  product's core value.
- Verification's cost is I/O, not cryptographic overhead — there is no
  "lighter" substitute that preserves the guarantee.
- Any state-based shortcut (ledger or sidecar manifest) can only be as
  trustworthy as the assumption that nothing changed the destination outside
  RollKeep's awareness, which cannot be guaranteed without re-reading the
  data — eliminating the shortcut's benefit.

## Consequences

- Repeated offloads from a card that isn't emptied will continue to fully
  re-copy and re-verify already-present files; this is accepted as correct,
  safe behavior rather than a bug to optimize away.
- The "slow" perception should be addressed by making the always-verify path
  legible (e.g., a receipt/summary showing bytes read, copied, and verified)
  rather than by making it skippable.
