# ADR 0005: Two-Pass Batch Hardware Verification (`F_NOCACHE` and Single `F_FULLFSYNC` Barrier)

Date: 2026-11-20
Status: Accepted

## Context

`StagingCopyEngine` previously ran copy and verify inline per file using `Foundation.OutputStream` and `Foundation.InputStream`, without `F_FULLFSYNC` or `F_NOCACHE`.
Because verification ran immediately after each file copy, macOS served the read-back verification from the RAM Unified Buffer Cache.
That check caught stream truncation and process memory corruption, but it did not catch bad physical sectors, drive controller corruption, or data loss from premature drive removal.

We evaluated per-file `F_FULLFSYNC` (Option A) against a two-pass batch pipeline (Option C):
- Per-file `F_FULLFSYNC` forces a hardware cache-flush barrier and a write-to-read head reversal on every single file. On a 5,000-file card, that causes thousands of extra HDD head seeks and increased SSD metadata write amplification.
- Writing without `F_NOCACHE` on the staging write descriptor also lets macOS retain clean pages in the RAM Unified Buffer Cache even after `F_FULLFSYNC`.

## Decision

- Run `StagingCopyEngine` as a unified two-pass batch pipeline (Option C):
  1. **Pass 1 (Copy):** Stream-copy all planned files to staging, compute each file's SHA-256 hash (`sourceHash`) in memory during the read stream, close, and atomically rename each temporary file to its staging path.
  2. **Single hardware flush barrier:** After all Pass 1 copy workers complete, issue `fcntl(fd, F_FULLFSYNC)` once on the destination volume (falling back to `fsync(fd)` when `errno` is `ENOTSUP`, `EINVAL`, or `ENOTTY`) to drain the drive's hardware write cache before Pass 2 begins.
  3. **Pass 2 (Verify):** Re-read all staged files sequentially (or up to `maxParallelCopies` on SSDs), compare each read-back SHA-256 hash and byte size against the Pass 1 record, check `shouldCancel()` per file and per 1 MiB chunk, and emit live `.phaseChanged(.verify)`, throttled `.fileVerifyProgress`, and live `.fileVerified` events.
- Gate hardware cache bypass and the flush barrier behind `hardwareVerification: Bool = true` on `IngestRequest` and `StagingCopyEngine.Configuration` (fixed at run start per `I-10`).
  - When `hardwareVerification` is `true`, set `fcntl(fd, F_NOCACHE, 1)` on both staging write descriptors (Pass 1) and verification read-back descriptors (Pass 2), and run the single `F_FULLFSYNC` barrier between Pass 1 and Pass 2.
  - When `hardwareVerification` is `false`, run the same two-pass pipeline without `F_NOCACHE` and without the `F_FULLFSYNC` barrier.
- Leave source camera card reads buffered (`F_NOCACHE` is not set on source file descriptors).
- Do not expose a user-facing UI toggle or CLI flag now. Track the potential UI toggle as parked story `ST-18`.
- Record `hardware_verification` (`true` or `false`) in `SESSION_STARTED` and `command_started`.
- Split the macOS Launcher progress bar into separate monotonic Copy (`18% -> 52%`) and Verify (`52% -> 86%`) bands with live verified-item counters (`"X of Y items verified"`).

## Why

- Setting `F_NOCACHE` on staging writes stops macOS from keeping newly written pages in RAM without issuing per-file hardware barriers, so HDD and SSD controllers coalesce writes freely during Pass 1.
- Issuing `F_FULLFSYNC` once after Pass 1 drains the drive write cache for the entire batch instead of forcing thousands of per-file flushes and head reversals.
- Setting `F_NOCACHE` on Pass 2 read-backs forces physical media reads across the whole batch.
- Checking `shouldCancel()` per chunk and emitting live verify progress keep **Stop Import** responsive and the app UI accurate during long HDD verify passes.
- One unified two-pass pipeline matches `ROL-6` Section 11 literally and avoids maintaining two copy/verify architectures.

## Consequences

- Invariant `I-5`, Section 8, Section 9, and Section 10 in `docs/ROL-6-spec-and-invariants.md` now define the two-pass hardware-verified copy and verify pipeline as the default behavior.
- Silent disk corruption on an early file is detected at the start of Pass 2 (after Pass 1 copies all files) instead of immediately after that file. Data safety is unchanged because no unverified file ever commits (`I-3`, `I-5`, `I-7`).
- Story `ST-8` closes as `done`, and parked story `ST-18` tracks a potential future UI toggle.

## Revisit trigger

- Users with large ingests to external mechanical hard drives request a UI toggle to choose between OS-cached verification and direct hardware verification (`ST-18`).
- Benchmarks show that source camera card reads evict active user applications from macOS memory during large video ingests.
