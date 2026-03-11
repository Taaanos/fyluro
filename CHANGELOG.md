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

<!-- release-sections -->
