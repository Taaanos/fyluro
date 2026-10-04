# INV-1: Stop Import is slow during the scan

**Status:** Cause confirmed by receipts (2026-10-04). Fix not decided. · **Opened:** 2026-10-04 · **Reported by:** owner
**Kind:** Investigation. It is not part of the UI overhaul. It touches the engine, so it needs its own branch and the owner's approval.

## Symptom

The user presses **Stop Import**. In the copy phase the stop is instant (owner, 2026-10-04). In the scan phase the importing screen stays for 5 to 10 seconds or more. Then it shows "Import Stopped".

Screens: `docs/ui-overhaul/before/importing-scan-dark.png` (the scan phase of a 2259-file source) and `failure-stopped-dark.png`.

## What the spec says

ROL-6 §9, Cancel: "The run stops at the next phase, file or chunk boundary and ends as a failed session with the reason 'cancelled'." I-7 applies: the staging folder and the receipt stay.

The code follows this text. The scan has no file boundary where it checks the flag. No invariant is broken.

## Evidence from receipts (measured)

Source: `local test _ingest_receipts/`. The receipt timestamp has a resolution of 1 second.

| Run | Stop in | Scan start | Scan end (`SCAN_SUMMARY`) | Cancel logged | Result |
|---|---|---|---|---|---|
| `c46ffdd8` | scan | 19:35:29Z | 19:35:46Z (17 s) | 19:35:46Z, **phase `plan`** | The scan ran to the end: 2259 candidates, 2783 files checked. Then the run aborted. `RECEIPT_PDF_WRITTEN`, `SUMMARY`, and `SESSION_FINISHED` all came in the same second. |
| `731cc5a9` | copy | 19:44:20Z | 19:44:30Z (10 s) | 19:44:37Z, phase `copy` ("Ingest cancelled during copy") | Instant. The cancel was logged right after a `FILE_VERIFIED` event. |
| `f12c0a3b` | none (clean run) | 19:45:49Z | 19:45:49Z | — | 41 candidates. The scan took under 1 s. |

What this shows:
- **Scan stop.** The cancel error has phase `plan` and comes after a full `SCAN_SUMMARY`. This means the engine finished the whole scan before it read the flag. The wait is the rest of the scan: up to 17 s for this source.
- **Scan speed.** About 100 candidates per second on this source (1111 in 10 s, 2259 in 17 s). The wait grows with source size.
- **End-of-run work is not the cause.** The PDF, the summary, and the finish event all fall in the same second as the cancel, with 2259 candidates.
- **Copy stop is fast.** This matches the chunk check in the copy loop.

## How a stop travels (verified by reading the code)

1. `LauncherViewModel.stopIngest()` sets `stopRequestedByUser`, sets the status text "Stopping import...", and calls `activeRun.cancel()` (`LauncherViewModelIngest.swift:41-49`).
2. `IngestSession.cancel()` sets a lock-protected boolean (`CancellationFlag`, `IngestSession.swift`). Nothing is interrupted.
3. The engine reads the flag only at the points below.
4. After a throw, the engine runs `handlePipelineFailure` and `finalizeSession`, which also writes the PDF.
5. The `.finished` event reaches the view model. Only then does the screen change.

| Phase | Check | Interval |
|---|---|---|
| Before scan | `throwIfCancelled(.scan)` (`IngestPipelinePhases.swift:119`) | once |
| **During scan** | **none.** `preparationService.prepare(...)` takes no cancel input. `grep -ri cancel Sources/RollKeepCore` finds no match. | **whole scan** |
| After scan, before plan | `throwIfCancelled(.plan)` (line 221) | once |
| Before copy | `throwIfCancelled(.copy)` (line 522) | once |
| During copy | `shouldCancel` in the chunk loop (`StagingCopyEngine.swift:266`) | each 1 MiB chunk |
| During verify (read-back hash) | none (`StagingCopyEngine.swift:498-547`) | whole file |
| Before commit | `throwIfCancelled(.commit)` (line 770) | once |
| During commit | `onBeforeMove` (line 790) | each file |

Scan and plan are one call (`prepare()`). The plan itself is quick and is not a cause.

## Hypotheses: result

| ID | Hypothesis | Result |
|---|---|---|
| H1 | The scan cannot be interrupted. | **Confirmed** by the receipt of `c46ffdd8` and by the owner's report. |
| H2 | The read-back hash cannot be interrupted. A large video delays a stop in verify. | Not shown. The owner reports an instant stop in copy. The test files are photos (large video untested). Low priority. |
| H3 | The PDF and the summary delay the end of an aborted run. | **Refuted** for 1111 to 2259 candidates. The end-of-run work takes under 1 s. |
| H4 | The UI gives no sign that the stop worked. | Not measured. Real, but secondary. The delay is the main problem. |

## Options (no decision yet)

| Option | Change | Where | Effect |
|---|---|---|---|
| A | Give the scanner a `shouldCancel` closure. Check it once for each file in the traversal loop. Throw the cancel error. | `SourceScanner`, `IngestPreparationService`, `IngestPipelinePhases.swift` | Fixes H1. A stop in scan takes under 1 s. |
| B | Check the flag in the `hashFileSHA256` loop, each chunk. Keep the staged file. | `StagingCopyEngine.swift` | Fixes H2 if it is real. Not needed now. |
| D | Show a clear "Stopping..." state at once: disable the button, say what the app waits for. | S3 (UI only) | Fixes H4. Does not make the stop faster. |

Dropped: skipping the PDF for a stopped run (H3 is refuted).

**Recommendation:** do A, with a test that starts a run on a generated tree, calls `cancel()` after 200 ms, and checks the time to `.finished`. Do D in S3. Do B only if a large-video test shows a delay.

## Spec check

- ROL-6 §9 (Cancel): A moves the stop to a finer boundary. The text stays true. Add "scan file" to the list of boundaries in the same commit as A.
- I-1: unchanged. The scan only reads.
- I-3, I-5: unchanged. A scan stop happens before any copy.
- I-7: a scan stop leaves no staging folder (nothing was copied). The receipt records the cancel with phase `scan`.
- I-6: the receipt is still written.

## Related observation (for S3)

The importing screen in `importing-scan-dark.png` shows the title "Importing 230 items..." and the body "2259 files checked • 2259 import candidates". The owner says the difference probably comes from optimizations for videos, and that the optimizations are important. **Do not change this behavior.** S3 may change how the numbers are shown. S3 must not change how they are computed.
