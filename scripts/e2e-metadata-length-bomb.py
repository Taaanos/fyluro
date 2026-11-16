#!/usr/bin/env python3

"""
Regression check for RT-P1-10 (fixed): EmbeddedVideoMetadataTextParser's
regex captures (e.g. `Model\\s*[:=]\\s*([^\\r\\n<]+)`) have no max-length
bound of their own, so a crafted "Model:" field used to survive
sanitization as a single unbroken token, propagating into the camera
label / path components / PDF rendering. `sanitize()` now rejects any
value over 128 UTF-8 bytes (comfortably above any real camera identifier),
so both variants below are expected to fall back to "unknown-camera"
safely rather than blocking the run or producing an absurd folder name:

  extreme  (~1.9MB label): previously blew past macOS's ~255-byte-per-
           component NAME_MAX, aborting the WHOLE run (StagingCopyEngine/
           StagingCommitEngine cancel the whole OperationQueue on first
           failure) -- now falls back to unknown-camera and completes
           normally.
  boundary (~200-byte label): previously stayed filesystem-legal, so it
           silently produced an absurd-but-valid camera folder rather than
           aborting -- the "moderate" half of the original finding. Also
           now rejected by the same 128-byte cap and falls back to
           unknown-camera, since 200 > 128.

See docs/testing/red-team-ingest-test-matrix.md.
"""

import argparse
import json
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path


def build_hostile_video_bytes(model_length: int) -> bytes:
    return ("Model:" + ("A" * model_length)).encode("ascii")


def parse_final_json(output: str, stderr: str) -> dict:
    lines = output.splitlines()
    for index, line in enumerate(lines):
        if not line.lstrip().startswith("{"):
            continue
        candidate = "\n".join(lines[index:])
        try:
            return json.loads(candidate)
        except json.JSONDecodeError:
            continue
    raise AssertionError(f"unable to parse rollkeep JSON summary\nstdout:\n{output}\nstderr:\n{stderr}")


def run_variant(binary: Path, fixture_source: Path, label: str, model_length: int) -> None:
    with tempfile.TemporaryDirectory(prefix=f"rollkeep-e2e-metadata-bomb-{label}-") as workdir:
        work = Path(workdir)
        source = work / "source"
        dest = work / "dest"
        shutil.copytree(fixture_source, source)
        dest.mkdir(parents=True)

        # Baseline candidate count from rollkeep's own classification rules
        # (not naive file counting -- the fixture may contain files rollkeep
        # doesn't treat as candidates), so this only has to assert "+1".
        baseline_args = [str(binary), "--source", str(source), "--dest", str(dest), "--json", "--dry-run"]
        baseline_result = subprocess.run(baseline_args, capture_output=True, text=True)
        if baseline_result.returncode != 0:
            raise AssertionError(f"baseline dry-run scan failed unexpectedly: {baseline_result.stderr}")
        baseline_candidates = parse_final_json(baseline_result.stdout, baseline_result.stderr)["counts"]["candidates"]

        (source / "hostile.mp4").write_bytes(build_hostile_video_bytes(model_length))
        expected_committed = baseline_candidates + 1

        args = [
            str(binary), "--source", str(source), "--dest", str(dest),
            "--json", "--pdf", "--max-parallel-copies", "1",
        ]
        result = subprocess.run(args, capture_output=True, text=True)

        print(f"\n=== variant={label} model_length={model_length} ===")
        print(f"exit code: {result.returncode}")

        pdf_files = list(dest.rglob("*.pdf"))
        print(f"PDF produced: {bool(pdf_files)}" + (f" ({pdf_files[0].stat().st_size} bytes)" if pdf_files else ""))

        if result.returncode != 0:
            raise AssertionError(
                f"expected variant={label} to complete VERIFIED (no whole-run-abort), "
                f"got exit {result.returncode}\nstdout:\n{result.stdout}\nstderr:\n{result.stderr}"
            )

        summary = parse_final_json(result.stdout, result.stderr)
        print(f"status: {summary.get('status')} / {summary.get('status_label')}")
        committed = summary.get("counts", {}).get("committed")
        print(f"committed: {committed} (baseline {baseline_candidates} + hostile.mp4)")
        if summary.get("status_label") != "VERIFIED":
            raise AssertionError(f"expected status_label=VERIFIED, got {summary.get('status_label')}")
        if committed != expected_committed:
            raise AssertionError(
                f"expected all {expected_committed} files (baseline {baseline_candidates} + "
                f"hostile.mp4) to be committed (no whole-run-abort), got committed={committed}"
            )

        hostile_final_paths = [
            path for path in dest.rglob("*")
            if path.is_file() and "hostile" in path.name.lower()
        ]
        if not hostile_final_paths:
            raise AssertionError("expected hostile.mp4's committed copy to exist under dest")

        longest_component = max(
            (len(part) for path in dest.rglob("*") for part in [path.name] + [p.name for p in path.parents]),
            default=0,
        )
        print(f"longest single path component created under dest: {longest_component} chars")
        if longest_component > 128:
            raise AssertionError(
                f"expected every path component under dest to stay within the 128-byte "
                f"sanitize() cap, found one at {longest_component} chars"
            )

        hostile_path_str = str(hostile_final_paths[0])
        if "unknown-camera" not in hostile_path_str:
            raise AssertionError(
                f"expected hostile.mp4's oversized Model field to be rejected and fall back to "
                f"unknown-camera, got path {hostile_path_str}"
            )
        print(f"hostile.mp4 committed to: {hostile_final_paths[0]}")


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Confirm the unbounded embedded-metadata-string issue (RT-P1-10) no longer reproduces."
    )
    parser.add_argument("--binary", required=True, help="Path to the rollkeep binary.")
    parser.add_argument("--repo-root", required=True, help="Repository root.")
    args = parser.parse_args()

    repo_root = Path(args.repo_root).resolve()
    binary = Path(args.binary).resolve()
    fixture_source = repo_root / "Tests" / "TestingDirs" / "SD_CARD1"
    if not fixture_source.is_dir():
        raise AssertionError(f"missing source fixture: {fixture_source}")

    run_variant(binary, fixture_source, label="extreme", model_length=1_900_000)
    run_variant(binary, fixture_source, label="boundary", model_length=200)

    print("\nMetadata length-bomb regression check passed (RT-P1-10 stays fixed).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
