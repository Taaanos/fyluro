// RollKeepEngine
//
// The RollKeep ingest execution engine: staging copy + read-back verification,
// commit, receipt writing, and pipeline orchestration. Extracted from the
// `rollkeep` CLI target so both the CLI and the macOS app can drive ingest by
// linking this library directly, rather than the app spawning the CLI binary.
//
// This target depends on RollKeepCore (scan/plan/metadata) and adds the
// side-effectful I/O half of ingest.
