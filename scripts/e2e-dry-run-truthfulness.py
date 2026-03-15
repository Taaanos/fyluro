#!/usr/bin/env python3

import argparse
import hashlib
import json
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Dict, Sequence


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


def path_state(root: Path) -> Dict[str, Dict[str, object]]:
    state: Dict[str, Dict[str, object]] = {}
    for path in sorted(item for item in root.rglob("*") if item.is_file()):
        stat = path.stat()
        state[str(path.relative_to(root))] = {
            "sha256": sha256_file(path),
            "size": stat.st_size,
            "mtime_ns": stat.st_mtime_ns,
        }
    return state


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


def run_rollkeep_dry_run(binary: Path, source: Path, dest: Path) -> dict:
    args = [str(binary), "--source", str(source), "--dest", str(dest), "--dry-run", "--json"]
    result = subprocess.run(args, capture_output=True, text=True)
    if result.returncode != 0:
        raise AssertionError(
            f"rollkeep dry-run failed with exit code {result.returncode}\nstdout:\n{result.stdout}\nstderr:\n{result.stderr}"
        )
    return parse_final_json(result.stdout, result.stderr)


def parse_receipt_events(path: Path) -> list[dict]:
    with path.open() as handle:
        return [json.loads(line) for line in handle]


def summary_event(events: Sequence[dict]) -> dict:
    for event in reversed(events):
        if event["event_type"] == "SUMMARY":
            return event["data"]
    raise AssertionError("missing SUMMARY event in receipt")


def assert_destination_only_writes(
    before: Dict[str, Dict[str, object]],
    after: Dict[str, Dict[str, object]],
    scenario_root: Path,
    dest: Path,
) -> None:
    changed = []
    all_keys = set(before.keys()) | set(after.keys())
    for key in all_keys:
        if before.get(key) != after.get(key):
            changed.append(key)

    escaped = []
    for relative_path in changed:
        absolute = scenario_root / relative_path
        if not absolute.is_relative_to(dest):
            escaped.append(relative_path)

    if escaped:
        raise AssertionError(f"dry-run wrote outside destination root inside scenario workspace: {escaped}")


def assert_dry_run_summary(final_json: dict, receipt_summary: dict) -> None:
    if final_json.get("status") != "completed":
        raise AssertionError("dry-run final status must be completed")
    if final_json.get("status_label") != "DRY RUN (scan+plan)":
        raise AssertionError(f"unexpected dry-run status_label: {final_json.get('status_label')}")
    if final_json.get("dry_run") is not True:
        raise AssertionError("dry-run final summary must report dry_run=true")
    if final_json.get("idempotency", {}).get("classification") != "dry_run_not_applicable":
        raise AssertionError("dry-run must report idempotency classification dry_run_not_applicable")
    if final_json.get("counts", {}).get("copied") != 0:
        raise AssertionError("dry-run must report copied=0")
    if final_json.get("counts", {}).get("verified") != 0:
        raise AssertionError("dry-run must report verified=0")
    if final_json.get("counts", {}).get("committed") != 0:
        raise AssertionError("dry-run must report committed=0")
    if final_json.get("counts", {}).get("errors") != 0:
        raise AssertionError("dry-run must report errors=0")

    if receipt_summary.get("dry_run") is not True:
        raise AssertionError("receipt SUMMARY must report dry_run=true")
    if receipt_summary.get("verified_ok") is True:
        raise AssertionError("receipt SUMMARY verified_ok must be false for dry-run")
    if receipt_summary.get("totals_by_outcome", {}).get("planned_stage_and_commit", 0) <= 0:
        raise AssertionError("dry-run must include planned_stage_and_commit files")
    if receipt_summary.get("totals_by_outcome", {}).get("copied") != 0:
        raise AssertionError("dry-run receipt SUMMARY must report copied=0")
    if receipt_summary.get("totals_by_outcome", {}).get("verified") != 0:
        raise AssertionError("dry-run receipt SUMMARY must report verified=0")
    if receipt_summary.get("totals_by_outcome", {}).get("committed") != 0:
        raise AssertionError("dry-run receipt SUMMARY must report committed=0")

    touched_paths = receipt_summary.get("touched_paths", {})
    if touched_paths.get("written_staging_files"):
        raise AssertionError("dry-run must not write staging files")
    if touched_paths.get("written_final_files"):
        raise AssertionError("dry-run must not write final files")
    if touched_paths.get("move_operations"):
        raise AssertionError("dry-run must not record executed staging->final moves")
    if touched_paths.get("deleted_paths"):
        raise AssertionError("dry-run must not delete paths")


def assert_only_receipt_written_on_disk(dest: Path) -> None:
    entries = sorted(path for path in dest.rglob("*"))
    disallowed = []
    for path in entries:
        relative = path.relative_to(dest)
        if relative.parts and relative.parts[0] == "_ingest_receipts":
            continue
        disallowed.append(str(relative))

    if disallowed:
        raise AssertionError(f"dry-run created unexpected on-disk destination paths: {disallowed}")


def execute_source(binary: Path, source: Path, scenario_root: Path) -> None:
    dest = scenario_root / "dest"
    dest.mkdir(parents=True, exist_ok=True)
    outside_file = scenario_root / "outside-sentinel.txt"
    outside_file.write_text("outside sentinel\n", encoding="utf-8")

    source_before = file_manifest(source)
    scenario_before = path_state(scenario_root)

    final_json = run_rollkeep_dry_run(binary=binary, source=source, dest=dest)
    receipt_path = Path(final_json["receipt"]["path"])
    if not receipt_path.exists():
        raise AssertionError(f"dry-run receipt missing: {receipt_path}")
    events = parse_receipt_events(receipt_path)
    receipt_summary = summary_event(events)

    assert_dry_run_summary(final_json, receipt_summary)
    assert_only_receipt_written_on_disk(dest)

    scenario_after = path_state(scenario_root)
    assert_destination_only_writes(scenario_before, scenario_after, scenario_root, dest)

    source_after = file_manifest(source)
    if source_before != source_after:
        raise AssertionError(f"source fixture changed during dry-run for {source.name}")

    print(
        f"[pass] {source.name}: status_label={final_json['status_label']}, "
        f"planned_stage_and_commit={receipt_summary['totals_by_outcome']['planned_stage_and_commit']}"
    )


def main() -> int:
    parser = argparse.ArgumentParser(description="Run dry-run truthfulness E2E checks.")
    parser.add_argument("--binary", required=True, help="Path to the rollkeep binary.")
    parser.add_argument("--repo-root", required=True, help="Repository root.")
    args = parser.parse_args()

    repo_root = Path(args.repo_root).resolve()
    binary = Path(args.binary).resolve()
    testing_root = repo_root / "Tests" / "TestingDirs"

    sources = [
        testing_root / "SD_CARD1",
        testing_root / "SD_CARD2",
    ]
    for source in sources:
        if not source.is_dir():
            raise AssertionError(f"missing source fixture: {source}")

    with tempfile.TemporaryDirectory(prefix="rollkeep-e2e-dry-run-") as workdir:
        work_root = Path(workdir)
        for source in sources:
            execute_source(binary=binary, source=source, scenario_root=work_root / source.name.lower())

    print("Dry-run truthfulness E2E checks passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
