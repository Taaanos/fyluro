# ST-20: Custom path engine and preset templates

**Status:** `parked` (needs refinement before implementation)
**Raised:** 2026-11-22 · **Type:** Behavior and UI feature (needs spec review and updates before code)
**Spec / Invariants:** `I-2`, `I-6`, `I-9`, `I-10`, [ROL-6-spec-and-invariants.md](../../ROL-6-spec-and-invariants.md) (Sections 2, 4, 6, 7, and 10)

## Goal

Let users build custom destination folder schemas from path tokens in the app.
Include saved templates, a visual folder-tree preview, and safe handling for built-in v1 presets.

## Proposed tokens

- `YYYY`, `MM`, `DD`, `YYYYMM`: Date components from the file capture date.
- `camera-model`: Normalized camera model label.
- `camera-serial-number`: Camera body serial number from metadata.
- `media-type`: Media bucket (`Photos`, `Videos`, or `audio`).
- `raw-split`: Photo-only split (`RAW` or `Non-RAW`).
- `event-tag`: User-entered tag applied to all files in one run.

## UX and structure visualization

- Use a structured token bar instead of a free-form text field.
- Let users place tokens as folder segments or combine tokens in one segment with `-` or `_`.
- Show an `Event name` field on the main window when the active template uses `event-tag`.
- Show a live sample folder tree next to the editor (one RAW photo, one JPEG, one video with sidecar, and one audio file).
- Collapse conditional levels in the preview when a token does not apply (such as `raw-split` on video).
- Show a collapsible planned folder tree on the main window after Scan finishes, with file counts and byte totals per branch.
- Let users expand any planned folder to inspect filenames, `-1` conflict renames, and skipped duplicates.

## Persisting and choosing templates

- Represent the current v1 layouts as read-only built-in presets expressed in tokens.
- Migrate existing `LauncherPathSchemeMemory` settings on first launch so existing users keep identical output paths.
- Store user-created templates in `~/Library/Application Support/Fyluro/PathTemplates.json` with stable UUIDs, names, token arrays, and a schema version.
- Reuse the atomic write and `.corrupt-<timestamp>.json` backup pattern from `LauncherCameraCatalogFileStore`, plus export and import actions.
- Show pinned and recent templates at the top of the main picker, with a searchable list when many templates exist.
- Remember the last used template per destination root, with one-click manual override.
- Add a `Settings > Paths` tab to create, duplicate, rename, pin, delete, export, and import templates.

## Future idea: macOS decision model

- Keep any future on-device macOS model outside `FyluroCore` and `FyluroEngine` so `I-10` and `I-2` stay intact.
- Use the model only to propose choices in the UI before the user starts the run.
- Rank saved presets from the scan inventory (camera mix, media ratios, and date span).
- Detect multi-day date clusters on a card and suggest an `event-tag` or warn about mixed dates.
- Convert natural-language descriptions strictly into validated path tokens so `I-9` stays safe.
- Suggest friendly names for unknown model codes in `CameraCatalog.json` for user approval.
- Record only the user-approved template and `event-tag` in the receipt (`I-6`).

## Open questions for refinement

1. **Audio exception (ROL-6 Sections 4 and 6):** Decide if custom templates apply to audio or if audio skips camera and serial tokens.
2. **Missing metadata fallbacks:** Define exact fallback names when `camera-serial-number` is absent or when date tokens fail (`_unsorted`).
3. **Conditional level collapse:** Confirm that empty conditional levels (`raw-split` on video, blank `event-tag` if allowed) collapse without creating empty segments.
4. **Event tag rules:** Decide whether blank `event-tag` blocks run start or collapses, and define strict `I-9` path-component sanitization.
5. **Camera serial in paths:** Spec Section 6 forbids camera serial tokens in folder labels; update Section 6 when adding `camera-serial-number`.
6. **Camera catalog interaction:** Confirm whether `camera-model` uses the experimental `CameraCatalog.json` mapping or raw model codes.
7. **Collision warnings:** Decide whether the editor warns users when a template omits all date tokens (`I-2` suffix collisions).
8. **Receipt and CLI parity:** Decide whether `SESSION_STARTED` and `SUMMARY` add an `event_tag` field, and whether custom templates stay app-only.
