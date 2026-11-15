# ST-8: Hardware-verified storage writes (fsync and cache bypass)

**Status:** `open` (evaluation needed; waiting on owner decisions Q1 to Q4)
**Raised:** 2026-11-15 · **Type:** Behavior and performance evaluation (needs an ADR and spec review)
**Related:** `I-5`, `I-3`, [ROL-6-spec-and-invariants.md](../../ROL-6-spec-and-invariants.md) (Sections 3 and 5.4), [0001-no-verification-opt-out.md](../../adr/0001-no-verification-opt-out.md).

## Why this story exists

RollKeep promises that every ingested file is verified (`I-5`).
Today, [StagingCopyEngine.swift](../../../Sources/RollKeepEngine/StagingCopyEngine.swift) uses `Foundation.OutputStream` and `Foundation.InputStream`.
It does not call `fsync` or `fcntl(fd, F_FULLFSYNC)` on the copied file.
It does not set `fcntl(fd, F_NOCACHE, 1)` on the read-back stream.

Because verification runs immediately for each file, macOS serves the read-back verification from the RAM page cache.
This behavior verifies the copy stream, but it does not verify the physical disk media.

## What works today (do not break)

- The copy loop calculates a SHA-256 hash while it streams bytes from the source.
- The verification loop calculates a second SHA-256 hash by reading the staged file.
- The engine compares both hashes. If they differ, the ingest fails and keeps staging evidence (`I-7`).
- The check catches truncated files, stream errors, and process memory corruption.
- When a file exceeds available RAM, macOS flushes pages to disk and reads from physical media.

## The problem and the trade-off

Reading from the macOS RAM page cache creates an integrity gap:
1. **Hardware write errors:** If a bad sector or faulty drive controller corrupts physical data, the read-back reads clean bytes from RAM.
2. **Premature disconnection:** If a user unplugs an external drive immediately after ingest, dirty pages in RAM are lost.

Enforcing physical disk reads has a major performance cost:
- **Fast NVMe SSDs (1,000 to 3,000 MB/s):** Ingest speed change is small.
- **External mechanical hard drives (100 to 140 MB/s):** Verification duration doubles overall ingest time.
- Verifying a 100 GB ingest on an external hard drive takes about 14 minutes of physical disk reads.
- Verifying that same 100 GB in RAM takes only seconds.

## Options to evaluate

### Option A: Make direct hardware verification always active
- Call `fcntl(fd, F_FULLFSYNC)` on every copied staging file.
- Call `fcntl(fd, F_NOCACHE, 1)` before every read-back hash check.
- **Pros:** Maximum data safety. Fully catches hardware-level write errors.
- **Cons:** Significantly slows down ingest on external hard drives and slow flash drives.

### Option B: Add a verification level toggle in Settings
- Provide a setting in the app:
  - **Standard Verification (Default):** Stream-level SHA-256 verification via OS cache. Fast, protects against transfer corruption.
  - **Direct Hardware Verification:** Unbuffered read-back (`F_NOCACHE`) with disk flush (`F_FULLFSYNC`). Guarantees physical media integrity before formatting camera cards.
- Clearly explain the speed and durability trade-offs in the UI.
- **Pros:** Gives users control. Fast by default, with complete safety available for critical shoots.
- **Cons:** Adds a user setting. Requires an update to ADR 0001 and Invariant `I-5`.

### Option C: Optional batch verification pass at run end
- Copy all files with standard caching.
- Issue a volume sync after all files are in staging.
- Run an unbuffered `F_NOCACHE` read-back pass over all files before final commit.
- **Pros:** Amortizes disk flushes across the entire batch.
- **Cons:** Still requires full physical read bandwidth. Adds extra pipeline complexity.

## Open questions

Answer these in order before scheduling work:

1. **Should RollKeep provide a user toggle for verification depth?**
   (Standard fast verification vs Direct hardware verification)
2. **If a toggle exists, which mode should be the default?**
3. **Does Invariant `I-5` permit a software-level vs hardware-level verification choice?**
   (Check ADR 0001: ADR 0001 rejected skipping verification entirely, but did not discuss RAM cache bypass).
4. **Should source camera card reads also use `F_NOCACHE`?**
   (Prevents large video ingests from clearing useful user apps from macOS memory).

## Constraints

- The source camera card is never modified (`I-1`).
- Verification can never be turned off completely (`I-5`, ADR 0001).
- Failed runs must retain all evidence in staging (`I-7`).
- Any behavior change requires an ADR update and a spec update in `docs/ROL-6-spec-and-invariants.md`.

## Next step

Decide between Option A (unconditional hardware verification) and Option B (settings toggle with trade-off notice).
Record the decision in this file before implementation.
