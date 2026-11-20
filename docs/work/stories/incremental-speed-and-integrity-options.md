# ST-19: Incremental speed and integrity options (preliminary research)

**Status:** `parked` (preliminary research only; not scheduled)
**Raised:** 2026-11-20 · **Type:** Preliminary research and design evaluation (requires owner decisions, an ADR, and spec review before any code)
**Related:** `I-2`, `I-3`, `I-5`, `I-7`, [ROL-6-spec-and-invariants.md](../../ROL-6-spec-and-invariants.md) (Sections 1, 3, 7, 8, 11), [0001-no-verification-opt-out.md](../../adr/0001-no-verification-opt-out.md), [0005-hardware-verification-cache-bypass.md](../../adr/0005-hardware-verification-cache-bypass.md), `ST-13`, `ST-18`.

> [!NOTE]
> **Preliminary research:** This file records initial analysis only. None of these options are approved or scheduled. Every option must obey the priority order in `ROL-6` Section 1 (`Data integrity > Storage medium safety and longevity > Raw speed`) unless the owner explicitly approves a spec and ADR change.

## Goal

Investigate ways to increase ingest speed incrementally on fresh and repeat imports without adding any extra HDD or SSD wear.

Every candidate below keeps drive wear equal to or lower than the current baseline (`ADR 0005`).

## Current baseline (100 GB import)

- **Fresh import:** 100 GB card read + 100 GB staging write (`F_NOCACHE`) + 1 `F_FULLFSYNC` barrier + 100 GB physical read-back (`F_NOCACHE`) = **200 GB destination I/O**.
- **Repeat import (100% duplicates already in library):** [IngestPreparationService.swift](../../../Sources/FyluroCore/IngestPreparationService.swift) currently passes `existingFinalFiles: [:]`. Every file copies to staging, verifies from physical media, gets hashed against the final library during [StagingCommitEngine.swift](../../../Sources/FyluroEngine/StagingCommitEngine.swift), and then deletes from staging = **300 GB destination I/O** (including 100 GB of wasted SSD writes).

## Candidate options (reconsidered)

### Option 0: Live-hash pre-copy duplicate skip against the final library (zero integrity loss)

Before copying a file into staging, check whether the planned **final destination path in the library** already exists with the exact same byte size.
- On fresh imports, the file does not exist, so the check costs one `stat()` call.
- If a same-size file already exists at the final path (or its `-1`, `-2` conflict-suffix chain), compute live SHA-256 hashes on the source file and on the existing library file.
- If the live hashes match, record `duplicate_not_copied` and skip writing to staging completely.
- If the hashes differ, run the normal staging copy, verify, and `-1` suffix commit.

**Impact:**
- **Speed:** Cuts total destination I/O on repeat imports by two-thirds.
- **HDD / SSD wear:** Eliminates 100% of wasted staging writes on repeat imports.
- **Integrity:** Zero loss. Still hashes live bytes on both the card and the final library.

**Edge cases and caveats to check before implementation:**
1. **Film Mode (`I-4`):** Film Mode rewrites photo EXIF bytes at commit, so a Film Mode photo never matches an existing library file by source hash. Disable Option 0 for Film Mode photos.
2. **Same-size hash collisions:** If two different files share a filename and exact byte size, hashing the source file before Copy reads that source file twice (rare, zero destination wear).
3. **RAM cache pressure:** Reading existing library files with `F_NOCACHE` prevents large repeat imports from evicting open user apps from macOS memory.
4. **Spec alignment:** `ROL-6` Section 11 and `ADR 0001` currently state that repeat runs re-copy and re-verify every file. Adopting Option 0 requires a small spec and ADR update even though it never trusts stored state.

---

### Option 1: OS-cached verification (`hardwareVerification = false`, tracked in `ST-18`)

Keep the two-pass SHA-256 check, but disable `F_NOCACHE` and the post-copy `F_FULLFSYNC` barrier.

**Impact:**
- **Speed:** Up to 2x faster on HDDs when the batch fits inside free Mac RAM; small gain (10% to 25%) on NVMe SSDs.
- **HDD / SSD wear:** Lower HDD spin time; equal or slightly lower SSD wear.
- **Integrity:** Misses bad physical sectors, faulty drive controllers, and premature drive disconnection for pages still served from RAM.

**Reconsidered caveat:**
- When an import is much larger than free Mac RAM (for example, 100 GB on a 16 GB Mac), macOS evicts early pages before Pass 2 starts. Pass 2 still reads most files from disk, while pushing user apps out of RAM.

---

### Option 2: Sampled physical read-back on large files (> 64 MiB)

Keep Pass 1 full stream copy with `F_NOCACHE` and the single `F_FULLFSYNC` barrier. In Pass 2:
- Run full-file `F_NOCACHE` read-back on small files (photos and sidecars `<= 64 MiB`).
- On large files (`> 64 MiB`, mostly videos), read back fixed offsets with `F_NOCACHE` (for example, first 1 MiB, middle 1 MiB, and last 1 MiB) and compare against hashes captured at those same offsets during Pass 1.

**Impact:**
- **Speed:** Cuts 100 GB HDD video imports nearly in half, **even when the batch exceeds Mac RAM**.
- **HDD / SSD wear:** Lower HDD spin time; zero extra SSD wear. Restricting sampling to files `> 64 MiB` keeps extra HDD seeks tiny (for example, 20 large videos add only ~40 seeks).
- **Integrity:** Catches drive disconnects, broken controllers, truncated writes, and container header/footer corruption. **Misses** silent single-sector bit flips in unsampled interior blocks of large videos.
- **Spec impact:** Weakens `I-5` and Section 8; requires an ADR and explicit opt-in UI disclosure.

---

### Option 3: Metadata or sampled pre-copy duplicate skip on repeat runs

Before copying to staging, skip files when the final library path already has matching `size + mtime` (or `size + mtime + 64 KiB` head/tail fingerprint).

**Impact:**
- **Speed:** 10x to 100x faster on repeat runs of unformatted cards.
- **HDD / SSD wear:** Dramatically lowers SSD writes and HDD spin time on repeat runs.
- **Integrity:** Misses silent bit-rot in already-committed library files and external edits that preserve `size` and `mtime`.
- **Spec impact:** Directly reopens `ADR 0001` Option B.

---

### Option 4: Size-only verification (drop Pass 2 read-back)

Copy all files to staging, run one `F_FULLFSYNC` barrier, verify only `stat().st_size == expectedBytes`, and commit.

**Impact:**
- **Speed:** ~2x faster on HDDs; 30% to 50% faster on SSDs.
- **HDD / SSD wear:** Halves HDD active time; same SSD writes.
- **Integrity:** Catches truncation and OS write errors only. **Misses all silent byte-level corruption.**
- **Spec impact:** Directly violates `I-5` and `ADR 0001` Option A. Listed only as the outer boundary of the spectrum; not recommended.

---

## Rejected options (do not pursue)

1. **Swapping SHA-256 for a faster non-cryptographic hash (XXH3, CRC32):** Apple Silicon hardware `CC_SHA256` runs at 1.5 to 2.5 GB/s per core. Card readers, HDDs, and USB SSDs are I/O-bound, so CPU hash swaps yield near-zero real speedup (`ADR 0001`).
2. **Skipping staging (`I-3`) to write directly into final folders:** Same-volume atomic `rename(2)` takes microseconds per file (~0.25s per 5,000 files). Skipping staging gives ~0% speedup while destroying crash isolation (`I-7`) and clean library boundaries.
3. **Increasing parallel copy streams on rotational HDDs:** Increases HDD head seeking and slows transfers down (`ST-13`).

## Open questions (for future evaluation)

1. Should **Option 0** (live-hash pre-copy duplicate skip against the final library, zero integrity loss) be split out as a standalone enhancement?
2. If Fyluro ever offers a speed-vs-integrity setting (`ST-18`), should it stop at **Option 1** (OS-cached) and **Option 2** (sampled large-file verify), and permanently exclude **Option 3** and **Option 4**?
3. How should the receipt and `VERIFIED` badge label a run that used sampled or OS-cached verification so the user is never misled about `VERIFIED`?

## Next step

Keep this story parked as preliminary research. If repeat-ingest speed or SSD write reduction becomes a priority, split **Option 0** into its own scoped ticket and evaluate the `ROL-6` / `ADR 0001` update first.
