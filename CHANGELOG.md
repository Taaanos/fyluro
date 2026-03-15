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

<!-- release-sections -->
