# Security Threat Model

This document maps RollKeep security risks to product invariants and automated tests.

## System scope and attack surface

- **Components:** `RollKeepCore`, `RollKeepEngine`, `rollkeep` (CLI), and `rollkeepLauncher` (macOS app).
- **Network:** RollKeep makes zero network connections and collects zero telemetry.
- **Dependencies:** `RollKeepCore` and `RollKeepEngine` have zero external dependencies. The CLI uses only `swift-argument-parser` in [Package.swift](../Package.swift).
- **Untrusted inputs:** Camera card files, filenames, directory trees, symlinks, and embedded EXIF/XMP/QuickTime metadata.

## Threat-to-evidence map

| Threat | Invariant | Automated test |
| --- | --- | --- |
| Unexpected writes or source card edits | `I-1`, `I-2`, `I-9` | [e2e-timestamp-and-write-audit-test.sh](../scripts/e2e-timestamp-and-write-audit-test.sh) |
| Symlink escapes and path traversal | `I-9` | [e2e-symlink-skip-test.sh](../scripts/e2e-symlink-skip-test.sh) |
| Hostile filenames (separators, control or bidi characters) | `I-9`, `I-10` | [e2e-hostile-filenames-test.sh](../scripts/e2e-hostile-filenames-test.sh) |
| Oversized or malformed embedded metadata | `I-4` | [e2e-metadata-length-bomb-test.sh](../scripts/e2e-metadata-length-bomb-test.sh) |
| Silent copy corruption or disk errors | `I-3`, `I-5`, `I-7` | [e2e-verify-failure-test.sh](../scripts/e2e-verify-failure-test.sh), [e2e-fault-injection-test.sh](../scripts/e2e-fault-injection-test.sh) |
| Crash or signal interruption during ingest | `I-6`, `I-7` | [e2e-crash-restart-recovery-test.sh](../scripts/e2e-crash-restart-recovery-test.sh), [e2e-cli-signal-cancellation-test.sh](../scripts/e2e-cli-signal-cancellation-test.sh) |

## Further evidence

- Product invariants (`I-1` to `I-10`): [ROL-6-spec-and-invariants.md](ROL-6-spec-and-invariants.md) (Section 3).
- Red-team safety test matrix: [red-team-ingest-test-matrix.md](testing/red-team-ingest-test-matrix.md).
- E2E fixture matrix: [e2e-ingest-matrix.md](../Tests/e2e-ingest-matrix.md).
