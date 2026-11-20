#!/usr/bin/env python3

"""
Regression check for RT-P0-12 (fixed): a crafted ISO-BMFF box header with an
extended size near UInt64.max previously crashed the real fyluro CLI via a
Swift integer-overflow trap (SIGTRAP). ISOBMFFBoxWalker.swift now uses
overflow-safe arithmetic and treats an overflowing size the same as any
other malformed/oversized box (stop parsing, fall back gracefully) instead
of crashing. See docs/testing/red-team-ingest-test-matrix.md.

This script asserts the FIXED behavior: no crash, and the crafted file is
ingested normally (as a video candidate with no resolvable embedded
metadata, like any other file whose box structure the walker can't parse).
"""

import argparse
import hashlib
import json
import shutil
import struct
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Dict


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def file_manifest(root: Path) -> Dict[str, str]:
    return {
        str(path.relative_to(root)): sha256_file(path)
        for path in sorted(item for item in root.rglob("*") if item.is_file())
    }


def build_overflow_crash_blob() -> bytes:
    """
    Minimal ISO-BMFF box sequence that used to trip the overflow trap in
    ISOBMFFBoxWalker.readBoxes: a valid 8-byte box advances `offset` to a
    non-zero value, then a box with size=1 ("use 64-bit extended size")
    supplies an extended size of UInt64.max, so `offset + boxSize` would
    overflow a naive checked UInt64 addition.
    """
    box1 = struct.pack(">I", 8) + b"free"  # size=8, type="free", no payload
    box2 = struct.pack(">I", 1) + b"moov" + struct.pack(">Q", 0xFFFFFFFFFFFFFFFF)
    return box1 + box2


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
    raise AssertionError(f"unable to parse fyluro JSON summary\nstdout:\n{output}\nstderr:\n{stderr}")


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Confirm the ISOBMFFBoxWalker overflow-trap crash (RT-P0-12) no longer reproduces."
    )
    parser.add_argument("--binary", required=True, help="Path to the fyluro binary.")
    parser.add_argument("--repo-root", required=True, help="Repository root.")
    args = parser.parse_args()

    repo_root = Path(args.repo_root).resolve()
    binary = Path(args.binary).resolve()
    fixture_source = repo_root / "Tests" / "TestingDirs" / "SD_CARD1"
    if not fixture_source.is_dir():
        raise AssertionError(f"missing source fixture: {fixture_source}")

    with tempfile.TemporaryDirectory(prefix="fyluro-e2e-boxwalker-crash-") as workdir:
        work = Path(workdir)
        source = work / "source"
        dest = work / "dest"
        shutil.copytree(fixture_source, source)
        dest.mkdir(parents=True)

        # Baseline candidate count from fyluro's own classification rules
        # (not naive file counting -- the fixture may contain files fyluro
        # doesn't treat as candidates), so the crash.mp4 case below only has
        # to assert "+1", not guess an absolute count.
        baseline_args = [str(binary), "--source", str(source), "--dest", str(dest), "--json", "--dry-run"]
        baseline_result = subprocess.run(baseline_args, capture_output=True, text=True)
        if baseline_result.returncode != 0:
            raise AssertionError(f"baseline dry-run scan failed unexpectedly: {baseline_result.stderr}")
        baseline_candidates = parse_final_json(baseline_result.stdout, baseline_result.stderr)["counts"]["candidates"]

        crash_blob = build_overflow_crash_blob()
        (source / "crash.mp4").write_bytes(crash_blob)
        source_before = file_manifest(source)

        cli_args = [
            str(binary), "--source", str(source), "--dest", str(dest),
            "--json", "--max-parallel-copies", "1",
        ]
        result = subprocess.run(cli_args, capture_output=True, text=True)

        if result.returncode < 0:
            raise AssertionError(
                f"expected a clean exit, but the CLI was killed by signal {-result.returncode} "
                f"-- the RT-P0-12 overflow-trap crash has regressed\n"
                f"stdout:\n{result.stdout}\nstderr:\n{result.stderr}"
            )
        if result.returncode != 0:
            raise AssertionError(
                f"expected exit code 0 (VERIFIED), got {result.returncode}\n"
                f"stdout:\n{result.stdout}\nstderr:\n{result.stderr}"
            )

        summary = parse_final_json(result.stdout, result.stderr)
        if summary.get("status_label") != "VERIFIED":
            raise AssertionError(f"expected status_label=VERIFIED, got {summary.get('status_label')}")
        if summary.get("counts", {}).get("errors") != 0:
            raise AssertionError(f"expected errors=0, got {summary.get('counts', {}).get('errors')}")
        expected_candidate_count = baseline_candidates + 1
        if summary.get("counts", {}).get("candidates") != expected_candidate_count:
            raise AssertionError(
                f"expected {expected_candidate_count} candidates (baseline {baseline_candidates} + "
                f"crash.mp4 included as a normal file, not dropped or crashed on), "
                f"got {summary.get('counts', {}).get('candidates')}"
            )

        print(
            f"[confirmed] no crash: fyluro CLI completed VERIFIED with crash.mp4 included as an "
            f"ordinary candidate ({summary['counts']['candidates']} total, 0 errors) -- the box "
            "walker now gracefully stops instead of trapping on the overflowing extended size."
        )

        source_after = file_manifest(source)
        if source_before != source_after:
            raise AssertionError(
                "source fixture changed during ingest -- 'no delete on card' invariant check failed"
            )

        committed_crash_copies = [
            p for p in dest.rglob("*")
            if p.is_file() and p.read_bytes() == crash_blob
        ]
        if not committed_crash_copies:
            raise AssertionError("expected a byte-identical committed copy of crash.mp4 under dest")
        print(f"[confirmed] crash.mp4 committed byte-identically to {committed_crash_copies[0]}")

    print("Box-walker overflow-trap regression check passed (RT-P0-12 stays fixed).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
