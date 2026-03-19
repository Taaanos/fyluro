# AGENTS.md

## Mandatory Spec-First Workflow

Before implementing, modifying, or reviewing any feature, always read:
- `docs/ROL-6-spec-and-invariants.md`

Treat that document as the product source of truth for production behavior and invariants.
Architecture direction: RollKeep is app-first, with the CLI as an engine/complementary interface. Some capabilities may be app-only by design.

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

## User Workflow Preferences (Persistent)
- After finishing each ticket, if there were code changes, always run the CLI tool locally against the project test directories, covering both sources:
  - `Tests/TestingDirs/SD_CARD1`
  - `Tests/TestingDirs/SD_CARD2`
- After finishing each story, always build the macOS app bundle so the user can test the current app directly from `dist/RollKeep.app`.
- When committing, use conventional commit prefixes (for example: `feat:`, `fix:`, `refactor:`, `test:`, `docs:`, `chore:`).
- Write commit messages with enough context to explain the scope and intent of the change (not terse one-liners without ticket/feature detail).

## Lessons Capture Workflow (Persistent)
- Maintain and use `AGENTS.md` as a running repository memory for actionable lessons.
- Every time a non-trivial finding is discovered, explicitly decide whether it should be persisted in `AGENTS.md`.
- If the finding is worth keeping, append or update a concise lesson entry in `AGENTS.md`.
- Consult `AGENTS.md` at the start of related tasks and whenever prior decisions or invariants may apply.
