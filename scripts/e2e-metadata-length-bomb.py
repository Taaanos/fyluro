#!/usr/bin/env python3

"""
Reproduces RT-P1-10: EmbeddedVideoMetadataTextParser's regex captures (e.g.
`Model\\s*[:=]\\s*([^\\r\\n<]+)`) have no max-length bound, so a crafted
"Model:" field survives sanitizeCameraLabel/slug() as a single unbroken
token. Two variants are checked against the real CLI:

  extreme  (~1.9MB label): expected to blow past macOS's ~255-byte-per-
           component NAME_MAX, failing the copy phase -- and because
           StagingCopyEngine/StagingCommitEngine cancel the whole
           OperationQueue on the first failure, this is expected to block
           ingestion of every OTHER file on the card in that run too, not
           just the poisoned file.
  moderate (~200-byte label): expected to stay filesystem-legal and
           complete VERIFIED, producing an absurd-but-valid camera folder.

See docs/red-team-ingest-test-matrix.md.
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

        (source / "hostile.mp4").write_bytes(build_hostile_video_bytes(model_length))
        good_files_before = sorted(p.name for p in source.iterdir() if p.name != "hostile.mp4")

        args = [
            str(binary), "--source", str(source), "--dest", str(dest),
            "--json", "--pdf", "--max-parallel-copies", "1",
        ]
        result = subprocess.run(args, capture_output=True, text=True)

        print(f"\n=== variant={label} model_length={model_length} ===")
        print(f"exit code: {result.returncode}")

        pdf_files = list(dest.rglob("*.pdf"))
        print(f"PDF produced: {bool(pdf_files)}" + (f" ({pdf_files[0].stat().st_size} bytes)" if pdf_files else ""))

        if label == "extreme":
            if result.returncode == 0:
                raise AssertionError(
                    f"expected the extreme variant to fail (ENAMETOOLONG-class error), got exit 0\n"
                    f"stdout:\n{result.stdout}\nstderr:\n{result.stderr}"
                )
            summary = parse_final_json(result.stdout, result.stderr)
            print(f"status: {summary.get('status')} / {summary.get('status_label')}")
            committed = summary.get("counts", {}).get("committed")
            print(f"committed: {committed} (of {len(good_files_before)} otherwise-good files on the card)")
            if committed not in (0, None):
                raise AssertionError(
                    f"expected 0 of the {len(good_files_before)} good files to be committed "
                    f"(whole-run-abort blast radius), but {committed} were committed"
                )
        else:
            if result.returncode != 0:
                raise AssertionError(
                    f"expected the moderate variant to complete VERIFIED, got exit {result.returncode}\n"
                    f"stdout:\n{result.stdout}\nstderr:\n{result.stderr}"
                )
            summary = parse_final_json(result.stdout, result.stderr)
            print(f"status: {summary.get('status')} / {summary.get('status_label')}")
            hostile_final_paths = [
                path for path in dest.rglob("*")
                if path.is_file() and "hostile" in path.name.lower()
            ]
            longest_component = max(
                (len(part) for path in dest.rglob("*") for part in [path.name]),
                default=0,
            )
            print(f"longest single path component created under dest: {longest_component} chars")
            if not hostile_final_paths:
                raise AssertionError("expected hostile.mp4's committed copy to exist under dest")


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Confirm CLI-level reachability of the unbounded embedded-metadata-string issue (RT-P1-10)."
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
    run_variant(binary, fixture_source, label="moderate", model_length=200)

    print("\nMetadata length-bomb E2E check passed (both variants behaved as documented).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
