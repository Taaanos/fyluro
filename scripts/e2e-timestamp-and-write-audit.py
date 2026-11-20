#!/usr/bin/env python3

import argparse
import hashlib
import json
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Dict, Iterable, List, Optional, Sequence, Tuple


NANOSECONDS_PER_SECOND = 1_000_000_000
TIMESTAMP_TOLERANCE_NS = NANOSECONDS_PER_SECOND


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
    raise AssertionError(f"unable to parse fyluro JSON summary\nstdout:\n{output}\nstderr:\n{stderr}")


def run_fyluro(binary: Path, source: Path, dest: Path) -> dict:
    args = [str(binary), "--source", str(source), "--dest", str(dest), "--json"]
    result = subprocess.run(args, capture_output=True, text=True)
    if result.returncode != 0:
        raise AssertionError(
            f"fyluro failed with exit code {result.returncode}\nstdout:\n{result.stdout}\nstderr:\n{result.stderr}"
        )
    return parse_final_json(result.stdout, result.stderr)


def parse_receipt_events(receipt_path: Path) -> List[dict]:
    with receipt_path.open() as handle:
        return [json.loads(line) for line in handle]


def summary_event(events: Sequence[dict]) -> dict:
    for event in reversed(events):
        if event["event_type"] == "SUMMARY":
            return event["data"]
    raise AssertionError("missing SUMMARY event in receipt")


def assert_touched_paths(summary_payload: dict, dest: Path, source: Path) -> None:
    touched = summary_payload["touched_paths"]
    receipt_fallback_prefix = str(Path(tempfile.gettempdir()) / "fyluro" / "_ingest_receipts")
    dest_prefix = str(dest)
    source_prefix = str(source)

    for key in [
        "created_directories",
        "planned_final_files",
        "planned_staging_files",
        "written_final_files",
        "written_staging_files",
        "deleted_paths",
    ]:
        for value in touched.get(key, []):
            if not value.startswith(dest_prefix):
                raise AssertionError(f"{key} escaped destination root: {value}")
            if value.startswith(source_prefix):
                raise AssertionError(f"{key} touched source root: {value}")

    for move_key in ["move_operations", "planned_move_operations"]:
        for entry in touched.get(move_key, []):
            if not entry["from"].startswith(dest_prefix) or not entry["to"].startswith(dest_prefix):
                raise AssertionError(f"{move_key} escaped destination root: {entry}")

    for receipt_path in touched.get("written_receipt_files", []):
        if receipt_path.startswith(dest_prefix):
            continue
        if receipt_path.startswith(receipt_fallback_prefix):
            continue
        raise AssertionError(f"receipt write escaped allowed roots: {receipt_path}")


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
        raise AssertionError(f"writes escaped destination root inside scenario workspace: {escaped}")


def committed_events(events: Iterable[dict]) -> List[dict]:
    committed: List[dict] = []
    for event in events:
        if event.get("event_type") != "FILE_COMMITTED":
            continue
        data = event.get("data", {})
        if data.get("status") == "committed" and data.get("outcome") == "committed":
            committed.append(event)
    return committed


def stat_birthtime_ns(path: Path) -> Optional[int]:
    stat = path.stat()
    birthtime = getattr(stat, "st_birthtime", None)
    if birthtime is None:
        return None
    return int(birthtime * NANOSECONDS_PER_SECOND)


def assert_timestamp_preservation(events: Sequence[dict]) -> Tuple[int, int, int]:
    committed = committed_events(events)
    if not committed:
        raise AssertionError("missing committed files in receipt")

    comparable_birthtime_count = 0
    preserved_birthtime_count = 0

    for event in committed:
        data = event["data"]
        source_path = Path(data["source_path"])
        final_path = Path(data["final_path"])

        if not source_path.exists():
            raise AssertionError(f"committed event referenced missing source file: {source_path}")
        if not final_path.exists():
            raise AssertionError(f"committed event referenced missing final file: {final_path}")

        source_stat = source_path.stat()
        final_stat = final_path.stat()
        mtime_delta = abs(source_stat.st_mtime_ns - final_stat.st_mtime_ns)
        if mtime_delta > TIMESTAMP_TOLERANCE_NS:
            raise AssertionError(
                f"mtime mismatch exceeds tolerance for {final_path}: "
                f"source={source_stat.st_mtime_ns} final={final_stat.st_mtime_ns}"
            )

        source_birthtime_ns = stat_birthtime_ns(source_path)
        final_birthtime_ns = stat_birthtime_ns(final_path)
        if source_birthtime_ns is None or final_birthtime_ns is None:
            continue

        comparable_birthtime_count += 1
        birthtime_delta = abs(source_birthtime_ns - final_birthtime_ns)
        if birthtime_delta <= TIMESTAMP_TOLERANCE_NS:
            preserved_birthtime_count += 1

    if comparable_birthtime_count > 0 and preserved_birthtime_count == 0:
        raise AssertionError("creation date was never preserved when comparable birthtime values were available")

    return len(committed), comparable_birthtime_count, preserved_birthtime_count


def execute_source(binary: Path, source: Path, scenario_root: Path) -> None:
    dest = scenario_root / "dest"
    dest.mkdir(parents=True, exist_ok=True)

    outside_file = scenario_root / "outside-sentinel.txt"
    outside_file.write_text("outside sentinel\n", encoding="utf-8")
    sibling_dir = scenario_root / "sibling"
    sibling_dir.mkdir(parents=True, exist_ok=True)
    (sibling_dir / "sibling-sentinel.txt").write_text("sibling sentinel\n", encoding="utf-8")

    source_before = file_manifest(source)
    scenario_before = path_state(scenario_root)

    summary = run_fyluro(binary, source, dest)
    if summary.get("status") != "completed":
        raise AssertionError(f"{source.name} run did not complete: {summary}")
    if summary.get("status_label") != "VERIFIED":
        raise AssertionError(f"{source.name} run did not report VERIFIED")
    if summary.get("counts", {}).get("errors") != 0:
        raise AssertionError(f"{source.name} run reported non-zero errors")

    receipt_path = Path(summary["receipt"]["path"])
    if not receipt_path.exists():
        raise AssertionError(f"{source.name} missing receipt: {receipt_path}")

    events = parse_receipt_events(receipt_path)
    receipt_summary = summary_event(events)
    assert_touched_paths(receipt_summary, dest, source)

    committed_count, birthtime_comparable, birthtime_preserved = assert_timestamp_preservation(events)
    scenario_after = path_state(scenario_root)
    assert_destination_only_writes(scenario_before, scenario_after, scenario_root, dest)

    source_after = file_manifest(source)
    if source_before != source_after:
        raise AssertionError(f"{source.name} source fixture changed during run")

    print(
        f"[pass] {source.name}: committed={committed_count}, "
        f"birthtime_comparable={birthtime_comparable}, birthtime_preserved={birthtime_preserved}"
    )


def main() -> int:
    parser = argparse.ArgumentParser(description="Run timestamp-preservation and destination-write-audit E2E checks.")
    parser.add_argument("--binary", required=True, help="Path to the fyluro binary.")
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

    with tempfile.TemporaryDirectory(prefix="fyluro-e2e-ts-write-audit-") as workdir:
        work_root = Path(workdir)
        for source in sources:
            execute_source(binary=binary, source=source, scenario_root=work_root / source.name.lower())

    print("Timestamp preservation and destination write-audit E2E checks passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
