# ADR 0003: Boundary and Periodic Flushing for the Receipt Journal

Date: 2026-11-15
Status: Accepted

## Context

`ReceiptWriter` called `fsync(fd)` after every appended NDJSON line. A normal ingest emits roughly 6 events per file (`FILE_COPY_STARTED`, `FILE_COPIED`, `FILE_VERIFY_STARTED`, `FILE_VERIFIED`, `FILE_COMMIT_STARTED`, `FILE_COMMITTED`).

On a 5,000-file ingest, this behavior causes roughly 30,000 serialized disk flushes.
- On an HDD, those flushes move the disk head repeatedly and stall post-phase bursts.
- On an SSD, those flushes trigger small metadata and flash page writes.
- On macOS, `fsync(fd)` does not flush the drive's own write cache anyway. Only `fcntl(F_FULLFSYNC)` does.

ADR 0001 rejected skipping verification reads. It did not evaluate receipt flush frequency.

## Decision

- Keep `write()` immediate for every receipt event so lines enter the OS page cache and live readers see them at once.
- Stop calling `fsync(fd)` after every single event line.
- Flush the receipt file (`fsync`) at phase boundaries, after post-phase event loops, on `ERROR` events, and when at least 2 seconds have elapsed since the last flush.
- Flush `SESSION_FINISHED` with `fcntl(fd, F_FULLFSYNC)` on Darwin, falling back to `fsync(fd)` if the filesystem returns `ENOTSUP`, `EINVAL`, or `ENOTTY`.
- Keep lines written since the last successful flush in memory so a failed flush on the destination replays them to the local fallback receipt.
- Flush any remaining dirty data before closing the file descriptor.

## Why

- Separating `write()` from `fsync()` removes roughly 99% of receipt flushes while keeping every event line in the OS page cache.
- Process crashes (`SIGKILL` or runtime traps) preserve data already passed to `write()`.
- Only a sudden power loss or drive unplug can lose at most 2 seconds of in-progress lines during copy or scan. RollKeep does not resume crashed runs (Section 11), so the next run starts safely.
- Using `F_FULLFSYNC` once at `SESSION_FINISHED` protects the final receipt state against drive write-cache loss at negligible cost.
- Replaying unflushed lines on flush failure prevents silent event gaps when switching to the local fallback.

## Consequences

- Invariant `I-6` and Section 10 in `docs/ROL-6-spec-and-invariants.md` change from per-event flush to boundary and 2-second periodic flushing.
- The 2026-07-16 performance audit's "Out of scope" note is updated to point to this ADR.
- Tight post-phase loops still call `write()` once per event. Evaluating write-buffer batching for those loops is tracked separately in `ST-14`.

## Revisit trigger

- A power-loss or unexpected-disconnect recovery workflow needs sub-2-second receipt durability mid-copy.
- A target filesystem shows errors or unacceptable latency on `F_FULLFSYNC` at session end.
