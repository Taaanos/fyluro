# UI-S6: Accessibility and finish

**Status:** Not started · **Depends on:** S0–S5 merged (this story checks the finished UI) · **Branch:** `ui/s6-accessibility-finish` · **Size:** small to medium

## Goal

Close the accessibility gaps from the review. Check the finished UI under all appearance settings. Leave a before and after record.
Accessibility fixes for one screen (Reduce Motion on the route arrow, default and cancel buttons) belong to the story of that screen. S6 checks them and handles what remains.

## Why (principles)

- **Native first (#2).** System controls give most accessibility behavior for free, if custom parts do not break it. The remaining work is the custom parts: icon-only buttons, stat blocks, the route panel, and the color of secondary text.
- **Color carries meaning (#5).** The meaning must not depend on color alone. ✓ and ✗ icons and words go with green and red. Text must be readable. The `.tertiary` 11-pt hints in the old Film Mode sheet were not.
- A Mac app must work with the keyboard only and with VoiceOver. This is a checklist, not a feeling.

## Read first

`AGENTS.md`, `docs/ROL-6-spec-and-invariants.md` (presentation only; read §2 and §10), [README](README.md), [findings.md](findings.md) D.
Accessibility code at the time of the review: `accessibilityLabel` exists only on the Settings warning, the Camera Labels fields and trash button, and the example row. There is **no** `accessibilityReduceMotion` and **no** `keyboardShortcut` (S1.4, S2.3, and S3 add the shortcuts).

## Decisions to confirm before you write code

1. **Target level.** *Recommendation:* "good citizen": VoiceOver labels and grouping, full keyboard use, Reduce Motion, a check of Increase Contrast and Reduce Transparency, and a minimum contrast of 4.5:1 for body text. No formal audit or certificate.
2. **Announcements.** Should VoiceOver announce state changes (import started, completed, failed) with accessibility announcements? *Recommendation:* yes for completed and failed (one `AccessibilityNotification.Announcement` each). No for progress of each file (too many messages). `AccessibilityNotification` needs macOS 14. On macOS 13, use `NSAccessibility.post(element:notification:)` or skip. Confirm skip if it is awkward.
3. **Scope of the final record.** Commit only the story files. Keep screenshots untracked (S0 decision). Update the README status table. Confirm.

## Tickets

### UI-6.1 — VoiceOver labels and grouping
- Give labels and help to icon-only controls: the Film Mode `?` button and any other icon button.
- Stat blocks: use `.accessibilityElement(children: .combine)`. Then VoiceOver reads "Photos, 41" as one item.
- Route panel: one clear label ("From <source> to <destination>"). Give the `ProgressView` its progress value during import.
- Hide decorative icons (tiles, status glyphs next to text) from VoiceOver.
- Acceptance: ☐ every control can be reached and has a name in VoiceOver (⌘F5) on every screen ☐ the reading order matches the visual order.

### UI-6.2 — Keyboard-only check
- Turn on Full Keyboard Access (System Settings → Keyboard). Reach and use every control on every screen and sheet. Return is the default action. Esc cancels where a sheet or cancel exists. Custom backgrounds never clip the focus ring.
- Acceptance: ☐ a full import (choose source → import → open receipt → import another) works without the mouse.

### UI-6.3 — Contrast and system-settings matrix
- Check the contrast of secondary and tertiary text and tinted notice backgrounds in light and dark. Replace `.tertiary` text that carries instructions with `.secondary`.
- Check under: Increase Contrast, Reduce Transparency, Reduce Motion, a non-blue accent color, and both appearances.
- Acceptance: ☐ nothing is unreadable or invisible under any of these settings ☐ the results are written below ("Findings").

### UI-6.4 — Announcements (optional; decision 2)
- Post a VoiceOver announcement at completion and at failure (title and the key count or reason). The announcement must carry the same facts as the screen, including the Film Mode line when it shows.

### UI-6.5 — Close-out
- Save `after/` screenshots for every baseline state (same file names as `before/`). Compare them side by side.
- Update the README status table. Write down what you chose not to do.
- Release reminder: before you ship a release with these stories, run `scripts/release-app-smoke-test.sh --with-launcher-check` (AGENTS.md).

## Out of scope

Localization. VoiceOver verbosity tuning beyond labels. Any new feature.

## Verification

`swift build` · `swift test` · `scripts/run-dev-app.sh`. VoiceOver (⌘F5) walkthrough. Keyboard-only walkthrough. The System Settings matrix of 6.3. Optional: Xcode's Accessibility Inspector (if installed) for contrast values.

## Spec check

Presentation only: ROL-6 §2 (VERIFIED and failure information must stay available to assistive technology; announcements must carry the same facts as the screen).

## Findings (fill in during the story)

_empty_
