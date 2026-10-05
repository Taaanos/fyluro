# UI-S4: PDF receipt — fix the bugs, make the numbers add up, exceptions-first appendix

**Status:** Done, waiting for the owner's review of the build and the PDFs · **Depends on:** — (independent of S0–S3; a good low-risk first story) · **Branch:** `ui/s4-pdf-receipt` · **Size:** medium to large

## Confirmed decisions

The owner confirmed all recommendations on 2026-10-05.

1. Vocabulary: Found, Verified, Added to library, Already in library, Renamed, Errors, Data. Remove the "Copied" tile.
2. Sidecar label: derive it in the report builder from the extension. Use the `.wav` rule. No engine change.
3. Caps: 200 rows for the needs-a-look list, 200 for the renamed list, 60 for the folder table. Each cap has an "and N more" line. Duplicates are never listed one by one.
4. Page look: white page, light tint behind the header only, hero fits its content, Source and Destination in the header, one readable path-scheme line.
5. `buildReportLines`: remove it and its test.
6. Film Mode section: print every field that exists, with the film camera first, and the EXIF limit line.
7. Dates: keep the user's locale. Shorten a same-day range.

## Result (2026-10-05)

- Tickets 4.1, 4.2 and 4.3 are done on `ui/s4-pdf-receipt`.
- Checks: `swift test` passes. `scripts/run-e2e-tests.sh` passes. Only the five PDF files in `Sources/` changed, so the `.ndjson` events and the summary JSON are unchanged.
- Sample PDFs (not committed, `after/` is gitignored): `docs/ui-overhaul/after/receipt-after-*.pdf` (rerun with a rename, dry run, failed run, Film Mode).
- Choices made while building, so a later chat can see them:
  - A failed run shows Verified and Added to library as numbers. It shows "—" and "not completed" for Already in library and Renamed.
  - A dry run shows Would add and Would rename. Verified shows "Not run".
  - The dry-run message is a neutral notice. It is not in the red Attention list.
  - The needs-a-look list and the renamed list are tables. A row never splits across pages, and the header row repeats on each page.
  - Counts in tiles use thousands separators for the user's locale.
- Still to do by the owner: make one real Film Mode run in the app and check the Film Mode section. The CLI has no Film Mode option, so only unit tests and a rendered sample cover it.

## Goal

A receipt that a person can check in thirty seconds:
- a correct footer,
- numbers that add up, in the same words as the app,
- harmless events that do not look like warnings,
- a file section that shows *what needs a look* and *where the files landed*, not 50 almost identical rows.

The complete per-file record stays in the `.ndjson` (the PDF already links to it) and in the summary JSON. **This story does not change either one.**

## Why (principles)

- **Hierarchy (#1) and say it once (#7).** In the reviewed run, 41 of 50 rows were the same amber "Duplicate — not copied". The facts that a reader needs (what arrived, what was renamed, did anything fail) were hidden.
- **Color carries meaning (#5).** Amber means "needs attention". A skipped duplicate means the system worked. Today duplicates print amber 41 times (F3).
- **Evidence must agree with itself (F2).** Candidates 41 does not equal Copied 50. "Copied 50" is next to rows that say "not copied". A forensic document that contradicts itself is worse than none.
- **A cap that hides the end is a silent failure (F4).** `maximumOutcomes = 80` prints the *first* 80 files. On a big card, a late error never shows.

## Read first

`AGENTS.md`, `docs/ROL-6-spec-and-invariants.md` (§7 duplicate and conflict rules, §8 verification definition, §10 receipt and summary fields — **the summary fields are a contract. Add none in this story unless the user approves.**), [README](README.md), [findings.md](findings.md) F1–F8, G, H4.
Files:
- `Sources/RollKeepCore/PDFReceiptReportBuilder.swift` (report model and `build`).
- `Sources/RollKeepEngine/PDFReceiptExporter.swift`, `PDFReceiptPageComposer.swift`, `PDFReceiptPageComposerSections.swift`.
- `PDFReceiptRenderingSupport.swift` (palette, text renderer, `drawFooter`).
- `IngestSummaryBuilder.swift:40-110` (shape of `per_file_outcomes`).

Tests:
- `Tests/rollkeepTests/PDFReceiptReportBuilderTests.swift`. Two tests will change on purpose: `testContextRowsAreTrimmedToSixEntries` and `testPerFileOutcomesAreCappedToPreviewLimit`.
- `Tests/RollKeepEngineTests/PDFReceiptExporterTests.swift`.
- `PDFReceiptRenderingSupportBenchmarkTests.swift`.

Facts:
- `per_file_outcomes[].outcome` is `committed` or `duplicate_not_copied` after commit. It is `stage_and_commit` for planned files that did not run (dry run or unfinished run).
- A `collision_suffix` key means the file was renamed.
- **There is no sidecar flag.** Only `media_type` exists.

## Decisions to confirm before you write code

1. **Vocabulary** (shared with the app, S3). *Recommendation:* **Found** (all planned files; subtitle "41 media + 9 sidecars") · **Verified** · **Added to library** · **Already in library** · **Renamed** (a subset of Added, with the line "same name, different content — kept both") · **Errors** · **Data**. Remove the "Copied" tile. It repeats Verified and contradicts the duplicates row. Check this identity in tests: for a completed run, Found = Added + Already in library. For a failed or unfinished run, show "Not completed" for the rest.
2. **Sidecar label (F6).** Option (a): derive it in the report builder from the file extension with the sidecar allowlist, and use the ROL-6 §5 WAV rule (a `.wav` with `media_type != audio` is a sidecar of a video). Option (b): add an `is_sidecar` key to `per_file_outcomes` in `IngestSummaryBuilder` (a small, additive engine change in the summary JSON). *Recommendation:* (a). It needs no engine change. The `.wav` rule is a best effort.
3. **Caps for the exception lists.** *Recommendation:* the needs-a-look list and the renamed list each have a cap of 200 rows and an explicit line "and N more — see the .ndjson". The landed-folders table has a cap of 60 rows and the line "and N more folders". Never list duplicates one by one.
4. **Page look.** *Recommendation:* a white page (good for printing). The status header keeps a light tint. The hero box fits its content. Source and Destination move into the header block. One readable path-scheme line, for example "Year/YearMonth › Camera › Photos › RAW/Non-RAW". Confirm.
5. **`buildReportLines` (the plain-text version).** Nothing in `Sources/` calls it. Only tests do. Keep it in sync with the new model, or remove it and its test (with the user's approval)? *Recommendation:* remove it if it is really unused. Check with `grep` and ask the user.
6. **Film Mode block in the receipt (finding H4).** Film Mode records the camera and film that made the shots. The receipt never says that Film Mode was used. The summary JSON **already** has `film_mode` (`used`, `year`, `month`, `camera`, `film_stock`, `iso`, `lens`, `shot_at_iso`, `development_notes`, `scanner`, `creator`, `copyright`, `exif_applied_count`, `exif_skipped_count`; see `IngestSummaryBuilder.swift:150-190`). This is presentation only. It needs no engine or summary change. *Recommendation:* when `film_mode.used` is true, add a **Film Mode** section under the header: "Shot on <camera> · <film stock> · ISO <iso> (shot at <shot_at_iso>) · <Month YYYY>". Then add lens, development notes, digitized-with (scanner), and creator and copyright when they exist. Add the honest limit line: "EXIF written to N files; M RAW files kept their original camera metadata" (from the two counts). Do not show the section when Film Mode was not used. Confirm which fields to print (all that exist, or only camera, stock, and date).
7. **Date and locale.** Dates follow the user's locale (the reviewed PDF showed "3. Oct 2026"). *Recommendation:* do not change this. Shorten a same-day range to "23 Sep 2026, 17:49–19:23".

## Tickets

### UI-4.1 — Page layout: footer, header, hero, background
- **Footer (F1).** Right-align "Session <first 8 characters> • Page N" with `singleLineWidth`. Never start it at a fixed offset. The full session ID stays in the header block. Check that "Page N" is visible on every page.
- **Header (F7, F8).** One header block: title, status badge, Generated, full Session, Source, Destination. Remove the duplicate "Generated" row. Compute the hero height from its content (no empty 40 % at the bottom).
- **Path scheme (F7).** Show it once, in readable form, with sensible wrapping. Do not print the `_unsorted` variant unless unsorted files exist. Avoid raw `|` and `<>` (the font shows `|` as "I").
- **Background (F8).** A white page. Keep the tint only behind the status header.
- **Film Mode section (decision 6).** Add `filmMode` to `PDFReceiptReport`. Build it from `input.summary["film_mode"]`. It is `nil` when `used` is false or missing. Draw it between the header and the metric tiles. Tests: used, not used, some optional fields missing, RAW-skipped counts.
- Update `contextRows` and the test that pins "trimmed to six entries".
- Acceptance: ☐ the footer is fully on the page and page numbers show ☐ no split "Run Context" section ☐ the header has source and destination ☐ page 1 has no large empty areas.

### UI-4.2 — Numbers, words, and colors
- Rebuild the metric tiles as decision 1 says, in `PDFReceiptReportBuilder.build` (current code at `:232-245`). Compute *Found* from the outcomes list (so it includes sidecars), not from `scanSummary.candidates.count`. Show the media and sidecar split.
- Color and tone: **Added** is success. **Already in library** is neutral. **Renamed** is neutral or info (amber only if you decide that a rename needs attention). **Errors** is danger when more than 0, and success if 0. The per-file duplicate status text is neutral gray (`fileOutcomeStatus`, `PDFReceiptPageComposerSections.swift:286`).
- Sidecar label (decision 2): `SIDECAR` instead of `PHOTO` for `.xmp` and similar files.
- Tests: add or update `PDFReceiptReportBuilderTests`. Cover found, added, and already-in-library sums; completed, failed, and dry-run runs; sidecar classification including a `.wav` pair; tone mapping.
- Acceptance: ☐ for the reviewed run: Found 50 (41 media + 9 sidecars) · Added 9 (6 renamed) · Already in library 41 ☐ no tile contradicts another ☐ duplicates are never amber.

### UI-4.3 — Exceptions-first appendix
- Replace "File Appendix" with these parts, in this order:
  1. **Needs a look:** errors, failed, and not-completed files, in full detail. Only the cap from decision 3 can hide rows.
  2. **Renamed to avoid overwrite:** source → final path relative to the library, and the explanation line.
  3. **Where files landed:** a table with library-relative folder, photos, videos, audio, sidecars, total, for *added* files. For a dry run: "Would land".
  4. **Already in library:** one counted line and a pointer to the .ndjson.
- Print the library root once. Show other paths relative to it (F5). Remove `maximumOutcomes = 80`.
- Report model: replace `fileOutcomes` and `totalFileOutcomeCount` with the new groups. Keep what the tests and `buildReportLines` still need. Draw the table with the existing y-cursor and `ensureSpace` pagination in `PDFReceiptPageComposer`. Add a small table primitive in `PDFReceiptRenderingSupport`. Do not copy the line math.
- Edge cases to handle: dry run (no executed files), failed run (partial, with an attention section), zero files, more than 2000 files, long and non-ASCII paths, many errors.
- Acceptance: ☐ the reviewed run fits on 2 pages or fewer ☐ every renamed and error item is listed ☐ a big-card run (made up, 2000 entries or more) paginates and shows the "and N more" lines ☐ the `.ndjson` and summary JSON are byte-for-byte the same as before for the same run.

## Out of scope

Anything in the `.ndjson` or summary JSON. New receipt events. The in-app complete screen (S3; keep the vocabulary the same). A redesign of the receipt as HTML. A change of the app name (use `AppBrand.name`). The Verified label and skipped files (KI-2).

## Verification

`swift build` · `swift test` (the updated builder and exporter tests pass). Make real PDFs and **look at them**. The assistant can read a PDF directly. The user can open it in Preview.
- Completed run and its second run: `swift run rollkeep --source Tests/TestingDirs/SD_CARD1 --dest <scratch dir> --pdf` (twice; the second run is all duplicates). Do the same for `SD_CARD2`.
- Renamed rows: use the preseeded fixtures `Tests/TestingDirs/E2E_EXISTING_HDD_CONFLICT_PRESEEDED_SD1/2` (`scripts/existing-hdd-e2e.py` shows how they are used). Duplicates: `…_DUPLICATE_PRESEEDED_*`.
- Dry run: add `--dry-run --pdf`. Failure: use a fault-injection script (`scripts/e2e-fault-injection-test.sh`, `scripts/e2e-verify-failure-test.sh`) and open the PDF.
- Film Mode run: make one run with Film Mode on in the app and check the Film Mode section.
- Save `after/receipt-after-*.pdf` next to `before/receipt-before.pdf`.
- Check that ingest output did not change: compare the `.ndjson` and summary JSON of a run with fixed input, before and after (ignore timestamps and session IDs).

## Spec check

ROL-6 §7 (a duplicate is skipped safely; a conflict is renamed with a suffix; the wording must match), §8 (verified definition), §10 (every summary field that the PDF reads still comes from the same summary; none is added), §3 (receipt is always written; a PDF failure must not affect it; this story does not change that).

## Start prompt

```text
Read AGENTS.md, docs/ROL-6-spec-and-invariants.md, docs/ui-overhaul/README.md, docs/ui-overhaul/findings.md,
and docs/ui-overhaul/story-4-pdf-receipt.md. I am new to UI/UX. Explain the principle behind each change.
First ask me the questions in "Decisions to confirm". Wait for my answers. Write them in the story file.
Then implement ticket by ticket on ui/s4-pdf-receipt. Do the spec check before you write code.
Do not change the .ndjson receipt events or the summary JSON.
```
