# Story: Film Mode metadata strategy

**Status:** Open. Not scheduled. Needs owner decisions before any work.
**Raised:** 2026-10-05 · **Type:** Behavior change (needs a spec change and owner approval first)
**Related:** I-4 and the Film Mode limits in `docs/ROL-6-spec-and-invariants.md` (Sections 3 and 5), UI story S2 (`docs/ui-overhaul/story-2-film-mode-sheet.md`).

## Why this story exists

Film Mode is the one feature that rewrites file bytes. The product promise is "verified, not changed". Film Mode is a deliberate exception to that promise (I-4).
The purpose of Film Mode is good. Scanned film has the EXIF of the digitizer. Without Film Mode, the file goes into the wrong month folder with the wrong camera label.
The way Film Mode records the fix is the open question. It is not the purpose.

## What works today (do not re-open)

- Folder placement and the shot date for every photo, RAW included, come from the Film Mode override at planning time.
  This is independent of any EXIF rewrite. It already works.
- The receipt marks `film_mode_override`.

## The problem

Three limits come from the in-file EXIF rewrite (all in the spec):

| # | Limit | Effect |
|---|---|---|
| L1 | The code rewrites the staged file after verification. Nothing hashes it again. | The committed bytes are not the verified bytes. |
| L2 | A rewritten file never matches an existing library file by hash. | A second import of the same file is not a duplicate. |
| L3 | ImageIO cannot write EXIF into RAW files. | RAW files have the right folder but the scanner EXIF inside. |

## Options

**A. Keep the rewrite as it is.** No work. The limits stay. Keep showing them in the UI.

**B. Make the rewrite optional inside Film Mode.** Film Mode always sets placement and the receipt. A switch decides whether the code rewrites EXIF.
- Fixes L1 and L2 when the switch is off.
- Does not fix L3.

**C. Write the film data to a new XMP sidecar. Never change the photo.**
- Fixes L1, L2 and L3. The photo stays byte-identical and keeps full verification (I-4 and I-5 are intact for the photo).
- Needs new plan and copy plumbing. The current sidecar pipeline only copies sidecars that already exist on the card (see the 2026-07-17 decision).
- Open risk: not every tool reads the sidecar. Lightroom and Bridge do. Apple Photos and Finder may not.

**D. Rewrite with `exiftool`.** Handles every RAW format.
- Fixes L3 only. L1 and L2 stay.
- Needs a new dependency and the first `Process()` shell-out in the app. The app is unsigned (no notarization), so bundling a Perl runtime is untested.

**E. Re-hash after the rewrite.** Add a second verify pass for rewritten files.
- Fixes L1 only. It does not fix L2 or L3.
- Needs a change to Section 8, which says the check does not re-read the final file.

## Open questions

Answer these in order. Write each answer under "Decisions" below.

1. **What do you need most?** Pick one:
   - the photo bytes stay untouched (leads to C), or
   - other apps show the film camera when they open the photo, with no extra file (leads to A, B or D)?
2. **Which apps must show the film camera?** For example Apple Photos, Finder, Lightroom, Capture One, or an online gallery. Do they all read XMP sidecars?
3. **Is a second import of the same scan a real case for you?** (L2) If yes, the rewrite is a problem. If never, L2 does not matter.
4. **How many of your film scans are RAW or DNG?** (L3) If almost none, the RAW limit is small and option D is not worth a dependency.
5. **Is a sidecar next to every photo acceptable?** It adds one file for each photo in the library. It also changes the file count in the receipt.
6. **Can the owner accept a spec change to I-4?** Option C needs no I-4 exception for the photo. It needs a new rule for a created sidecar. I-9 allows new final library files, so it may already fit. Check this.
7. **Does the rewrite and a sidecar both need to exist?** (Both for maximum compatibility.) This is the most work.
8. **What happens to old imports?** Files already in the library keep their rewritten EXIF. Confirm that nothing changes for them.

## What each answer leads to

| If the answer says… | Then do |
|---|---|
| Untouched photo bytes matter most (Q1) | Option C. Write an ADR first. Then the spec. Then code. |
| Other apps must read the camera from the photo itself, and most scans are not RAW (Q1, Q4) | Option B. Small change. |
| Other apps must read the camera, and many scans are RAW (Q1, Q4) | Option D. Plan the dependency and the packaging first. |
| Nobody reads sidecars (Q2) | Do not do option C alone. |
| Duplicates of film scans are a real case (Q3) | Avoid option A. |

## Constraints for any option

- The source file is never changed (I-1). Film Mode only touches the committed copy.
- Verification stays on and cannot be skipped (I-5). Any new write must have a defined verification step.
- Writes go only to places that I-9 allows.
- Film Mode does not change filesystem dates (I-8).
- The change needs a record in `docs/adr/` and the spec must change in the same commit (`docs/working-style.md`).
- Test fixtures: DNG, ARW, CR2 and GPR exist locally. There is no CR3 fixture.

## Decisions

None yet. Record the date, each answer and the chosen option here.

## Revisit trigger

Revisit when one of these happens:
- A user reports a film scan that shows the scanner in another app.
- A user reports a duplicate film scan in the library.
- Work starts on a feature that needs XMP sidecar output.
- The distribution plan changes and a dependency such as `exiftool` becomes cheap.
