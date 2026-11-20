// FyluroEngine
//
// The Fyluro ingest execution engine: staging copy + read-back verification,
// append-only final commit, and NDJSON receipt logging. Factored out of the
// `fyluro` CLI target so both the CLI and the macOS app can drive ingest by
// calling Swift APIs directly instead of spawning a child process.
//
// This target depends on FyluroCore (scan/plan/metadata) and adds the
// side-effecting pipeline phases (copy, verify, commit, finalize).
