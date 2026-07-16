#!/usr/bin/env python3

"""
Reproduces RT-P0-12: a crafted ISO-BMFF box header crashes the real rollkeep
CLI via a Swift integer-overflow trap (SIGTRAP), rather than being isolated
as a per-file scan error. See docs/red-team-ingest-test-matrix.md.

This script currently ASSERTS THE CRASH OCCURS -- it documents a known,
unfixed bug rather than verifying safety. Once ISOBMFFBoxWalker.swift's
extended-size handling is hardened against overflow, this script's
expectation must be flipped (assert a clean per-file ERROR + non-crash exit
instead of a signal-terminated process).
"""

import argparse
import hashlib
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
    Minimal ISO-BMFF box sequence that trips the overflow trap in
    ISOBMFFBoxWalker.readBoxes: a valid 8-byte box advances `offset` to a
    non-zero value, then a box with size=1 ("use 64-bit extended size")
    supplies an extended size of UInt64.max, so the walker's checked
    `offset + boxSize` addition overflows and traps -- killing the whole
    process, not a catchable Swift error.
    """
    box1 = struct.pack(">I", 8) + b"free"  # size=8, type="free", no payload
    box2 = struct.pack(">I", 1) + b"moov" + struct.pack(">Q", 0xFFFFFFFFFFFFFFFF)
    return box1 + box2


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Confirm CLI-level reachability of the ISOBMFFBoxWalker overflow-trap crash (RT-P0-12)."
    )
    parser.add_argument("--binary", required=True, help="Path to the rollkeep binary.")
    parser.add_argument("--repo-root", required=True, help="Repository root.")
    args = parser.parse_args()

    repo_root = Path(args.repo_root).resolve()
    binary = Path(args.binary).resolve()
    fixture_source = repo_root / "Tests" / "TestingDirs" / "SD_CARD1"
    if not fixture_source.is_dir():
        raise AssertionError(f"missing source fixture: {fixture_source}")

    with tempfile.TemporaryDirectory(prefix="rollkeep-e2e-boxwalker-crash-") as workdir:
        work = Path(workdir)
        source = work / "source"
        dest = work / "dest"
        shutil.copytree(fixture_source, source)
        dest.mkdir(parents=True)

        (source / "crash.mp4").write_bytes(build_overflow_crash_blob())
        source_before = file_manifest(source)

        cli_args = [
            str(binary), "--source", str(source), "--dest", str(dest),
            "--json", "--max-parallel-copies", "1",
        ]
        result = subprocess.run(cli_args, capture_output=True, text=True)

        if result.returncode >= 0:
            raise AssertionError(
                "expected the CLI process to be killed by a signal (e.g. SIGTRAP from a Swift "
                f"overflow trap), got a normal exit with code {result.returncode}\n"
                f"stdout:\n{result.stdout}\nstderr:\n{result.stderr}"
            )

        signal_number = -result.returncode
        print(
            f"[confirmed] rollkeep CLI was killed by signal {signal_number} while scanning "
            "crash.mp4 -- RT-P0-12 is reachable via the real CLI deep scan (in addition to the "
            "Launcher's live card-preview scan, which needs no ingest action at all)."
        )

        source_after = file_manifest(source)
        if source_before != source_after:
            raise AssertionError(
                "source fixture changed after the crash -- 'no delete on card' invariant check failed"
            )
        if not dest.exists() or not list(dest.iterdir()):
            print(
                "[confirmed] destination has no partial writes: the crash happens during scan, "
                "before any staging/copy work begins."
            )

    print("Box-walker overflow-trap crash E2E check passed (crash reproduced as expected).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
