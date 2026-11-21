# AGENTS.md

Working rules for Fyluro.
The product source of truth is `docs/ROL-6-spec-and-invariants.md`.
If this file and the spec disagree, the spec wins. Stop and ask the user.
Architecture: Fyluro is app-first. The CLI shares the engine as a secondary interface. Some features are app-only.
Priority: Data integrity (`I-1` to `I-10`) > storage medium safety > raw speed (spec Section 1).

## Work Loop

### Code or behavior changes
1. Read the applicable sections of `docs/ROL-6-spec-and-invariants.md` and name them.
2. Stop and ask the user if the task conflicts with the spec or an invariant.
3. Settle open questions before you write code.
4. Update the spec in the same commit with user approval if behavior changes.
5. Build the smallest safe change. Prefer `IngestSimulationTests` and e2e tests (`LauncherAppE2E*`, `scripts/*e2e*-test.sh`).
6. Run `swift test` before each commit. Run targeted e2e tests before commit when needed.
7. Run `scripts/release-app-smoke-test.sh --version <v> --with-launcher-check` if you change launcher startup, source detection, or scan-on-launch (`LauncherViewModelActions.swift`, `LauncherVolumeDefaults.swift`, `LauncherContentView.swift`).
8. Include a "Spec check" note in your chat reply with the spec sections used.
9. Run `scripts/run-e2e-tests.sh` once before you push to `origin/main`.

### Other tasks
- **Tooling, test script, or build:** Settle open questions and build the smallest safe change. Run `swift test` or changed scripts. Skip "Spec check" if no spec section applies.
- **Docs only:** Read the spec only if the doc describes product behavior. Skip `swift test` and `scripts/run-e2e-tests.sh`.
- **Questions, reviews, or investigations:** Do not edit files or run build or test commands unless asked.
- **Work tracking:** Read `docs/work/README.md` only when you select work, check open bugs in the same area, or update ticket status.

### Commits
- Make one commit per ticket or logical change. Stage only changed files.
- Use a conventional prefix (`feat:`, `fix:`, `refactor:`, `test:`, `docs:`, `chore:`) with scope and intent.
- Do not add `Co-Authored-By` or other attribution lines.

## Non-Negotiable Invariants

Spec Section 3 holds the full wording and known limitations.
Refer to invariants by ID only. Do not copy full wording into other files.
Invariant changes require user approval and a spec update in the same commit.

- I-1. Never change the source card.
- I-2. Never overwrite the library.
- I-3. Route every file through staging in a fixed order.
- I-4. Preserve embedded metadata (only exception: Film Mode).
- I-5. Never disable or skip verification.
- I-6. Always write the receipt.
- I-7. Keep evidence on a failed run.
- I-8. Preserve filesystem dates.
- I-9. Write only to allowed places.
- I-10. Lock the path strategy at run start.

## Writing Style (ASD-STE100)

Write all new or edited docs and all chat replies in ASD-STE100:
- Keep sentences short (steps: <= 20 words; descriptions: <= 25 words).
- Put one idea in each sentence.
- Use active voice and imperative verbs for steps.
- Use one word for one meaning. Avoid idioms.
- Do not rewrite old docs without a request.

## Code Comments

Explain why code exists, not what it does.
Keep or add only:
- Invariant guards (`I-1` to `I-10`).
- Hardware and OS workarounds (`F_NOCACHE`, `fsync`, sandboxing, macOS API bugs).
- Binary layout rules (byte offsets, box types, endianness in metadata decoders).
- Non-obvious edge cases and regression-test reasons.

## References (load only when needed)

- **Decision log:** Record behavior or direction decisions in `docs/adr/` or the spec (Date, Context, Decision, Why, Revisit trigger).
- **Scripts:** Run `ls scripts/` for dev, fixture, e2e, and release scripts. Every script accepts `-h`.
