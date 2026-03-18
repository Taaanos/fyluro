# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

- No unreleased entries yet.

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
- add 2026-03-15 codebase audit findings

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

<!-- release-sections -->
