#!/usr/bin/env python3

import argparse
import hashlib
import shutil
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


def file_manifest(root: Path) -> Dict[str, Dict[str, object]]:
    manifest: Dict[str, Dict[str, object]] = {}
    for path in sorted(item for item in root.rglob("*") if item.is_file()):
        stat = path.stat()
        manifest[str(path.relative_to(root))] = {
            "sha256": sha256_file(path),
            "size": stat.st_size,
            "mtime_ns": stat.st_mtime_ns,
        }
    return manifest


def run_fyluro_expect_failure(binary: Path, source: Path, dest: Path) -> subprocess.CompletedProcess[str]:
    args = [str(binary), "--source", str(source), "--dest", str(dest), "--json"]
    result = subprocess.run(args, capture_output=True, text=True)
    if result.returncode == 0:
        raise AssertionError(
            f"expected overlap preflight failure but command succeeded\nstdout:\n{result.stdout}\nstderr:\n{result.stderr}"
        )
    return result


def assert_overlap_error_message(stderr: str, required_fragment: str) -> None:
    requirement = "Source and destination must be different folders with no nesting."
    if requirement not in stderr:
        raise AssertionError(f"missing overlap requirement text in stderr: {stderr}")
    if required_fragment not in stderr:
        raise AssertionError(f"missing expected overlap detail '{required_fragment}' in stderr: {stderr}")


def assert_no_ingest_artifacts(source_root: Path) -> None:
    receipts = list(source_root.rglob("_ingest_receipts"))
    staging = list(source_root.rglob("_ingest_staging"))
    if receipts:
        raise AssertionError(f"unexpected receipt directories created during preflight failure: {receipts}")
    if staging:
        raise AssertionError(f"unexpected staging directories created during preflight failure: {staging}")


def copy_source_fixture(source_fixture: Path, destination: Path) -> None:
    shutil.copytree(source_fixture, destination)


def run_source_equals_dest(binary: Path, source_fixture: Path, scenario_root: Path) -> None:
    source_clone = scenario_root / "source"
    copy_source_fixture(source_fixture, source_clone)

    before = file_manifest(source_clone)
    result = run_fyluro_expect_failure(binary=binary, source=source_clone, dest=source_clone)
    assert_overlap_error_message(result.stderr, "Both resolved to")

    after = file_manifest(source_clone)
    if before != after:
        raise AssertionError("source==dest preflight failure changed source clone contents")

    assert_no_ingest_artifacts(source_clone)
    print("[pass] source==dest preflight rejection")


def run_destination_nested_in_source(binary: Path, source_fixture: Path, scenario_root: Path) -> None:
    source_clone = scenario_root / "source"
    copy_source_fixture(source_fixture, source_clone)

    nested_dest = source_clone / "library"
    nested_dest.mkdir(parents=True, exist_ok=True)
    sentinel = nested_dest / "sentinel.txt"
    sentinel.write_text("nested destination sentinel\n", encoding="utf-8")

    before = file_manifest(source_clone)
    result = run_fyluro_expect_failure(binary=binary, source=source_clone, dest=nested_dest)
    assert_overlap_error_message(result.stderr, "is inside source")

    after = file_manifest(source_clone)
    if before != after:
        raise AssertionError("nested-destination preflight failure changed source clone contents")

    assert_no_ingest_artifacts(source_clone)
    print("[pass] destination nested in source preflight rejection")


def main() -> int:
    parser = argparse.ArgumentParser(description="Run overlap preflight E2E checks (source/destination overlap rejection).")
    parser.add_argument("--binary", required=True, help="Path to the fyluro binary.")
    parser.add_argument("--repo-root", required=True, help="Repository root.")
    args = parser.parse_args()

    repo_root = Path(args.repo_root).resolve()
    binary = Path(args.binary).resolve()
    source_fixture = repo_root / "Tests" / "TestingDirs" / "SD_CARD1"
    if not source_fixture.is_dir():
        raise AssertionError(f"missing source fixture: {source_fixture}")

    with tempfile.TemporaryDirectory(prefix="fyluro-e2e-overlap-013-") as workdir:
        run_source_equals_dest(binary=binary, source_fixture=source_fixture, scenario_root=Path(workdir))

    with tempfile.TemporaryDirectory(prefix="fyluro-e2e-overlap-014-") as workdir:
        run_destination_nested_in_source(binary=binary, source_fixture=source_fixture, scenario_root=Path(workdir))

    print("Overlap preflight E2E checks passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
