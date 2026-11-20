# ST-8: Hardware-verified storage writes (fsync and cache bypass)

**Status:** `done` (2026-11-20; see [0005-hardware-verification-cache-bypass.md](../../adr/0005-hardware-verification-cache-bypass.md))
**Raised:** 2026-11-15 · **Type:** Behavior and performance evaluation (ADR 0005 and spec update)
**Related:** `I-5`, `I-3`, [ROL-6-spec-and-invariants.md](../../ROL-6-spec-and-invariants.md) (Sections 3, 8, 9, 10), [0001-no-verification-opt-out.md](../../adr/0001-no-verification-opt-out.md), [0005-hardware-verification-cache-bypass.md](../../adr/0005-hardware-verification-cache-bypass.md).

## Why this story exists

RollKeep promises that every ingested file is verified (`I-5`).
Previously, [StagingCopyEngine.swift](../../../Sources/RollKeepEngine/StagingCopyEngine.swift) used `Foundation.OutputStream` and `Foundation.InputStream`.
It did not call `fsync` or `fcntl(fd, F_FULLFSYNC)` on copied files.
It did not set `fcntl(fd, F_NOCACHE, 1)` on staging writes or read-back streams.

Because verification ran immediately for each file, macOS served the read-back verification from the RAM page cache.
This behavior verified the copy stream, but it did not verify the physical disk media.

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
- Per-file `F_FULLFSYNC` also forces thousands of extra HDD head seeks and extra SSD metadata flushes on multi-thousand-file cards.

## Options evaluated

### Option A: Per-file `F_FULLFSYNC` and `F_NOCACHE`
- Call `fcntl(fd, F_FULLFSYNC)` on every copied staging file and `F_NOCACHE` before every read-back check.
- **Rejected:** Causes excessive per-file flush barriers and write-to-read head reversals on HDDs and extra metadata wear on SSDs.

### Option B: Add a verification level toggle in Settings
- Provide a user-facing Settings toggle now.
- **Deferred:** Parked as `ST-18`. Gate the engine behavior behind `hardwareVerification: Bool = true` now so a UI toggle can be added later if needed.

### Option C: Two-pass batch copy and unbuffered verification (Chosen)
- **Pass 1 (Copy):** Copy all files to staging with `fcntl(fd, F_NOCACHE, 1)` on staging write descriptors (when `hardwareVerification` is `true`) and store each file's `sourceHash` in memory. No per-file `F_FULLFSYNC`.
- **Single flush barrier:** Call `fcntl(fd, F_FULLFSYNC)` once on the destination volume after Pass 1 finishes (falling back to `fsync` when unsupported).
- **Pass 2 (Verify):** Re-read all staged files with `fcntl(fd, F_NOCACHE, 1)` on read-back descriptors, check `shouldCancel()` per chunk, and emit live UI verify progress.

## Owner decisions (2026-11-20)

1. **Should RollKeep provide a user toggle for verification depth?**
   Not right now. Enable Option C by default and gate hardware cache bypass and flush behind `hardwareVerification: Bool = true` on `IngestRequest` and `StagingCopyEngine.Configuration`. Park a potential future UI toggle in story `ST-18`.
2. **If a gate exists, which mode should be the default?**
   Direct hardware verification (`hardwareVerification = true`) is the default. Both modes use the same two-pass batch pipeline.
3. **Does Invariant `I-5` permit a software-level vs hardware-level verification choice?**
   Invariant `I-5` and Section 8 of `docs/ROL-6-spec-and-invariants.md` now define the two-pass batch hardware verification pipeline (`F_NOCACHE` on staging writes and reads, single `F_FULLFSYNC` barrier between Pass 1 and Pass 2) as the default behavior, gated by `hardwareVerification` (see ADR 0005).
4. **Should source camera card reads also use `F_NOCACHE`?**
   No. Leave source camera card reads buffered. Apply `F_NOCACHE` and the single `F_FULLFSYNC` barrier to destination staging writes and verification read-backs only.
