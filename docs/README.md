# Fyluro Documentation

This folder holds the product spec, guides, decisions, test plans, and work tracking for Fyluro.

## Product and user docs

| Path | Content |
| --- | --- |
| [ROL-6-spec-and-invariants.md](ROL-6-spec-and-invariants.md) | The source of truth for product behavior and invariants. |
| [user-guide/README.md](user-guide/README.md) | End-user guide for the macOS app. |
| [adr/](adr/) | Architecture decision records (`0001` to `0005`). |

## Engineering and testing

| Path | Content |
| --- | --- |
| [guides/exiftool-sync.md](guides/exiftool-sync.md) | Procedure to sync camera identification tables with ExifTool. |
| [security-threat-model.md](security-threat-model.md) | Threat-to-invariant and E2E test mapping. |
| [testing/red-team-ingest-test-matrix.md](testing/red-team-ingest-test-matrix.md) | Red-team safety test matrix and spot-check results. |
| [Tests/e2e-ingest-matrix.md](../Tests/e2e-ingest-matrix.md) | End-to-end test matrix and fixture mapping. |
| [audits/performance-audit-2026-07-16.md](audits/performance-audit-2026-07-16.md) | Performance audit of the scan and plan phase. |
| [audits/performance-audit-2026-07-16-part2.md](audits/performance-audit-2026-07-16-part2.md) | Performance audit of copy, verify, commit, receipts, and UI. |

## Work tracking

| Path | Content |
| --- | --- |
| [work/README.md](work/README.md) | Entry point for active bugs and stories. |
| [work/bugs.md](work/bugs.md) | Known bugs and gaps (`KI-N`). |
| [work/stories.md](work/stories.md) | Planned features and future work (`ST-N`). |
| [investigations/](investigations/) | Root-cause investigations linked from `bugs.md`. |
| [ui-overhaul/](ui-overhaul/) | UI overhaul stories (`UI-S0` to `UI-S6`) and findings. |
