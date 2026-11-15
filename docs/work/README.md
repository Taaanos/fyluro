# Work Index

This folder is the entry point for current bugs and future work in RollKeep.
The product source of truth is [ROL-6-spec-and-invariants.md](../ROL-6-spec-and-invariants.md).
Process rules are in [AGENTS.md](../../AGENTS.md).

## Where each type of work lives

- **Current bugs and known gaps:** [bugs.md](bugs.md)
- **Planned features and future work:** [stories.md](stories.md)
- **Large investigations:** `docs/investigations/` (linked from [bugs.md](bugs.md))
- **Large multi-ticket stories:** `docs/work/stories/` and `docs/ui-overhaul/` (linked from [stories.md](stories.md))

## Status values

- `open`: Confirmed or potential work that has not started.
- `in-progress`: Work is active on a branch.
- `blocked`: Work waits on an owner decision or external dependency.
- `deferred`: The owner chose not to work on this item now.
- `accepted`: The owner accepted the current behavior with no change.
- `parked`: Future idea or backlog item that is not scheduled.
- `done`: Work is complete and merged.

## Active bugs (quick view)

See [bugs.md](bugs.md) for full details, deferred gaps, and fixed bugs.

| ID | Summary | Status | Needs decision |
| --- | --- | --- | --- |
| KI-5 | Stop Import is slow during the scan | `open` | Yes (approve Option A in [INV-1](../investigations/INV-1-stop-import-latency.md)) |
| KI-6 | One inventory row can cover files with different camera model codes | `open` | Yes (fix vs remove feature) |
| KI-7 | App does not detect a card inserted after it opens | `open` | Yes (launch-only vs watch) |
| KI-8 | Failed or empty scan shows no reason, and failed text is wrong | `open` | Yes (button rule on fail) |
| KI-9 | Engine does not prevent idle sleep during an import | `open` | No |
| KI-10 | Destination commit follows directory symbolic links outside the library root | `open` | No |
| KI-11 | Overlap validator misses case differences and non-existing ancestor symlinks, and is not in the engine | `open` | No |
| KI-12 | Collision suffix on a 254-byte or 255-byte filename exceeds the 255-byte limit and fails commit | `open` | No |
| KI-13 | ExifDateParser drops capture date when timestamp falls into a DST spring-forward gap | `open` | No |
| — | Long-filename edge case from KI-1 (Film Mode temp name) | `open` (no ID) | Yes (assign KI-14 if tracked) |

## Active and blocked stories (quick view)

See [stories.md](stories.md) for parked ideas, backlog links, and closed stories.

| ID | Story | Status | Needs decision |
| --- | --- | --- | --- |
| UI-S6 | UI Overhaul: Accessibility and finish | `open` | Yes (3 decisions in [story-6-accessibility-finish.md](../ui-overhaul/story-6-accessibility-finish.md)) |
| UI-S3 | UI Overhaul: 3 deferred visual checks | `deferred` | No |
| ST-1 | Film Mode metadata strategy | `blocked` | Yes (Q1 to Q8 in [film-mode-metadata-strategy.md](stories/film-mode-metadata-strategy.md)) |
| ST-8 | Hardware-verified storage writes (fsync and cache bypass) | `open` | Yes (Q1 to Q4 in [hardware-verification-cache-bypass.md](stories/hardware-verification-cache-bypass.md)) |
| ST-9 | Prevent idle sleep during ingest | `open` | No |
| ST-10 | Live mount detection and Disk Image (.dmg) filtering | `open` | No |
| ST-11 | Graceful CLI signal handling (SIGINT, SIGTERM, SIGHUP) | `open` | No |
| ST-12 | Sanitize control and bidi characters in human CLI output | `open` | No |

## How to add or update work

1. Add bugs to [bugs.md](bugs.md) with the next `KI-N` ID.
2. Add features and future work to [stories.md](stories.md) with the next `ST-N` ID.
3. Put a separate file in `docs/investigations/` or `docs/work/stories/` only when an item needs long evidence or many tickets, then link it.
4. Keep the quick-view tables above in sync when an active item changes status.
