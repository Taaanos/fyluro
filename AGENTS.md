# AGENTS.md

## Mandatory Spec-First Workflow

Before implementing, modifying, or reviewing any feature, always read:
- `docs/ROL-6-mvp-spec-and-invariants.md`

Treat that document as the product source of truth for MVP behavior and invariants.

Required behavior for every feature task:
- Confirm spec alignment before writing code.
- If requirements are ambiguous, resolve using the spec first.
- If code/task instructions conflict with the spec, stop and ask the user before proceeding.
- In implementation summaries, include a short "Spec check" note listing the spec sections used.

## Non-Negotiable Invariants (must never be violated)
- No delete on card.
- No overwrite in library.
- Staging-first copy flow.
- Receipt always written (with fallback behavior defined in spec).
