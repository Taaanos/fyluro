# Changelog

All notable changes to this project will be documented in this file.

## [0.1.1] - 2026-03-11

### Added

- deliver polished PDF ingest receipts in CLI and app
- show active import file path in launcher progress

### Fixed

- preserve source file timestamps on committed ingest files
- avoid zsh readonly status variable in release clean-tree check
- support multiline changelog insertion in release tooling

### Changed

- speed up app scan and lazy video metadata fallback
- reduce video scan hot-path overhead for large card videos
- reduce transfer-time receipt write overhead in commit planning
- add success action to open source folder
- align AGENTS and ROL-6 spec to production app-first direction
- stop expensive video metadata traversal once required identity is found
- show elapsed time on completed imports
- add manual filesystem date sync script from media metadata
- rename ROL-6 spec file and codify metadata preservation invariants
- align known-video camera label expectation with current inference

## [0.1.2] - 2026-03-11

### Fixed

- resolve collision-planned duplicates correctly and tighten commit progress accounting

## [0.1.3] - 2026-03-11

### Added

- add static import source/destination route panel

### Changed

- add future-agent handoff pack templates
- automate one-command release cut workflow

## [0.1.4] - 2026-03-15

### Fixed

- use source mtime fallback for photos missing EXIF date
- normalize iPhone camera labels with rule registry

### Changed

- explain two-pass verification and read-back cost in README
- prefer embedded product names for opaque photo model codes

## [0.1.5] - 2026-03-15

### Added

- prioritize video sidecars for metadata and transfer
- refine PDF receipt spacing and visual rhythm

### Fixed

- reduce false-positive video camera labels from deep fallback

### Changed

- expand fixture edge coverage and add e2e ingest matrix

## [0.1.6] - 2026-03-15

### Added

- refine import route arrow flow animation in launcher

### Fixed

- handle case-insensitive filename collisions in destination planning
- detect DJI Mini 4 Pro labels from embedded video metadata
- normalize DJI model labels across camera variants

### Changed

- expand e2e matrix coverage for duplicate-collision fixture
- add deterministic receipt failover and verify-failure e2e coverage
- add deterministic fault-injection e2e coverage for ingest failure invariants
- add live scan telemetry heartbeat during import
- automate pending ingest e2e matrix coverage
- complete remaining e2e matrix automation
- add evidence-first camera identity resolver pipeline

## [0.1.7] - 2026-03-18

### Added

- implement ROL-6 v1 global path scheme (app-first)
- support additional cinema containers and warn on unknown large media extensions

### Fixed

- ingest package-contained AVCHD media and preserve launcher scan preview telemetry
- refine launcher settings pane and warning hover UX

### Changed

- slim fixture-heavy ingest tests for fast default runs
- add single unsorted summary warning in scan preview
- improve settings clarity with isolated sections and change-scoped warnings
- close e2e organization matrix coverage gaps
- close e2e organization matrix coverage gaps
- add app-surface launcher e2e gate and release prep wiring

## [0.1.8] - 2026-07-12

### Fixed

- relax regex for dji

### Changed

- speed up e2e feedback with fast fixture profiles
- split large launcher files into focused modules
- split CLI ingest flow and extract PDF report builder
- complete wave-1 complexity reduction with e2e gates
- remove unused config and skip-verify CLI surfaces
- Enrich fixtures with more camera models, and rework the e2e tests to use the new fixtures while keeping the same logic
- broaden DJI camera model mapping
- skip symlinks and warn the user, and lock behavior in e2e
- run all e2e tests before a new release

## [0.2.0] - 2026-07-13

### Changed

- extract ingest engine into RollKeepEngine library (Phase 1)
- typed event stream, cancellation, struct fault injection (Phase 2.1/2.2)
- run ingest in-process via RollKeepEngine; drop CLI spawn/parse/poll (Phase 2.3-2.5)
- remove dead RollkeepCLIExecutableLocator
- accurate progress bar across all phases

## [0.3.0] - 2026-07-15

### Added

- ensure enough disk space before ingesting
- add warning and context for skipped unreadable files. Lock behavior in e2e
- add Film Mode for digitized film EXIF override  Digitized film photos carry EXIF from the digitizing camera (scan date, DSLR model) rather than the original shoot. Film Mode lets the user declare the correct month/camera/film stock/ISO once per ingest and writes it into the committed copy's EXIF, which also drives folder placement. Opt-in, off by default, app-only; source files are never touched. Documents the resulting EXIF-rewrite exception in the ROL-6 invariants doc.
- add receipt-insights script for aggregating ingest history

### Fixed

- remove obsolete mix_camera label
- correct exFAT disk-space false-positive; add real-fs Unicode collision E2E
- suppress duplicate final SCAN_PROGRESS event in scanner
- wrap forensic-note text in PDF receipt to prevent overflow
- de-emphasize NDJSON jargon in PDF receipt copy
- encapsulate File Appendix entries in cards and tighten spacing
- use authoritative commit-time results for per_file_outcomes
- replace tool tip with ?-icon

### Changed

- add decision record on never skipping verification
- update e2e matrix and red-team docs with new scenarios and reflect the status quo
- redesign PDF receipt layout to cut clutter and prioritize correctly
- drop divider lines and File Appendix card boxes for a flatter look
- Replace blind video metadata scan with structured ISO-BMFF box decoding
- Enable box-walk vendor decoding in the fast preview scan too
- Reconcile photo vs. video camera labels for DJI and Samsung
- Skip tier-4 regex sweep entirely when no field anchors are present

## [0.4.0] - 2026-07-17

### Added

- add audio ingestion (standalone recordings + video-companion sidecars)
- accept drag-and-drop folders on Source/Destination cards
- show capture date range in Scan Preview panel
- surface scan errors/warnings in Scan Preview panel
- block Import on insufficient destination free space
- add optional Creator/Copyright fields to Film Mode

### Fixed

- harden ISOBMFFBoxWalker against integer-overflow crash (RT-P0-12)
- cap embedded video metadata string length at the source (RT-P1-10)
- ingest GoPro Raw (GPR) files
- reset Film Mode when starting a new import
- surface Film Mode's RAW EXIF skip instead of failing silently

### Changed

- add new-attack-surface red-team audit (RT-P0-12, RT-P1-10, RT-P2-04)
- mark RT-P0-12 and RT-P1-10 as fixed in the red-team matrix
- reconcile red-team docs and benchmark comments with the applied fixes
- add perfomance assessment docs
- cache preview-scan metadata for reuse at ingest start (Finding 1)
- move camera model-code catalog from hardcoded dict to JSON
- memoize per-bucket directory resolution in DestinationPathPlanner (Finding 2)
- add part-2 performance audit (copy/commit, receipt/UI, post-audit code)
- memoize per-bucket directory resolution in StagingCommitEngine (Finding A)

## [0.5.0] - 2026-07-20

### Added

- camera-ID port M0 - EXIF IFD reader, uuid box support, exiftool oracle harness
- camera-ID port M1 - MOV/MP4 vendor decoders, widen fallback gate
- camera-ID port M2 - native RAW/CR3/RAF/MRW fallback, RAW allowlist expansion
- camera-ID port M3 - AVCHD/M2TS camera extractor via H.264 SEI/MDPM
- add Lens, Shot at ISO, Development notes, and Scanner fields to Film Mode

### Fixed

- close preview-scan cache reuse gap opened by M1's OR-gate relax

### Changed

- camera-ID port M4 - investigate MXF, defer (no fixtures, no signal)

## [0.6.0] - 2026-10-05

### Added

- replace bundled camera catalog with user-maintained Camera Labels
- build the app icon from an Icon Composer bundle
- Film Mode summary row with Edit… that reopens the saved roll (UI-1.3)
- show an evidence stat grid and the Film Mode line on the Complete screen (UI-3.2)
- add one ResultActionBar for Complete and Failure screens (UI-3.3)
- validate the Film Mode year and ISO and say why Apply is disabled (UI-2.2)
- put Film Mode Cancel and Apply together with keyboard roles and focus (UI-2.3)
- UI-S4.1 PDF receipt page layout, footer, header and Film Mode section
- UI-S4.2 PDF receipt numbers that add up, app vocabulary, calm colors
- UI-S4.3 PDF receipt exceptions-first appendix
- UI-S5.1 Settings Library pane as a grouped Form
- UI-S5.2 and S5.3 Camera Labels grid layout and plain words
- UI-S5.5 Name... action opens Settings on Camera Labels (finding A7)
- UI-S5 camera labels must be unique; saving a label no longer rescans the card
- UI-S5 camera inventory shows the original code and the label as original (folder)
- UI-S5 allow one name for several camera codes again
- lock camera labels behind an experimental app setting (off by default)
- add New Folder to the destination folder picker

### Fixed

- place SwiftPM resource bundle where Bundle.module actually resolves it
- use a fixed-length hidden temp name so long source filenames no longer abort the run (KI-1)
- show the Cameras tile on Complete and make Import Another Card a plain action (UI-3.2, UI-3.3)
- let the failure message wrap instead of cutting it at one line (S3 follow-up)
- wrap Film Mode hints, align them left and separate the header (UI-2.1 follow-up)
- say that RAW files are not supported in Film Mode, without 'yet'
- keep the main window size in every state and make the result buttons consistent (S3 follow-up)
- let a state grow the window past the minimum height instead of cutting its bottom
- UI-S5.5 keep camera inventory counts clear of the scrollbar
- UI-S5 Camera Labels pane height, intro text, and no row jump; remove Name... link
- UI-S5 keep the scan preview on screen while a label edit rescans the card
- UI-S5 camera inventory shows original (folder) only for labels the scan applied
- UI-S5 let a long camera code wrap in the Camera Labels list
- align Settings panes (Library preview rows, footnotes, action bar) and use Sony sample names
- remove 'Current MVP status' from the CLI help text

### Changed

- add .jxl photo extension
- add LauncherTone tokens and AppBrand.name (UI-0.2)
- add Surface, NoticeBanner and StatItem shared launcher parts (UI-0.3)
- merge Source and Destination into one setup route panel (UI-1.1)
- compact Scan Preview with one stat grid and a drop zone (UI-1.2)
- one Import button and a status line that adds information (UI-1.4)
- let SwiftUI size the main window instead of resizing it by hand (UI-1.5)
- hide empty Scan Preview and make the window a silent source drop target (UI-1.2)
- show the route panel in importing, complete and failure states, honor Reduce Motion (UI-3.1)
- group the Film Mode sheet by role in a native Form (UI-2.1)
- add end-user guide for the RollKeep app
- rewrite README as a short developer entry point

<!-- release-sections -->
