#!/usr/bin/env python3

import argparse
import hashlib
import json
import os
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import Dict, Optional


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


def run_rollkeep(binary: Path, source: Path, dest: Path) -> dict:
    args = [str(binary), "--source", str(source), "--dest", str(dest), "--json", "--max-parallel-copies", "1"]
    result = subprocess.run(args, capture_output=True, text=True)
    if result.returncode != 0:
        raise AssertionError(
            f"rollkeep failed with exit code {result.returncode}\nstdout:\n{result.stdout}\nstderr:\n{result.stderr}"
        )
    return parse_final_json(result.stdout, result.stderr)


def wait_for_receipt_file(receipts_dir: Path, timeout_seconds: float) -> Path:
    deadline = time.monotonic() + timeout_seconds
    while time.monotonic() < deadline:
        receipts = sorted(receipts_dir.glob("*.ndjson"))
        if receipts:
            return receipts[0]
        time.sleep(0.1)
    raise AssertionError(f"timed out waiting for receipt file in {receipts_dir}")


def wait_for_verified_before_commit(receipt_path: Path, timeout_seconds: float) -> None:
    deadline = time.monotonic() + timeout_seconds
    while time.monotonic() < deadline:
        content = receipt_path.read_text(encoding="utf-8", errors="ignore")
        has_verified = '"event_type":"FILE_VERIFIED"' in content
        has_commit_started = '"event_type":"FILE_COMMIT_STARTED"' in content
        if has_verified and not has_commit_started:
            return
        time.sleep(0.1)
    raise AssertionError("timed out waiting for verify-complete state before commit")


def parse_ndjson_events(path: Path) -> list[dict]:
    events: list[dict] = []
    with path.open() as handle:
        for line in handle:
            line = line.strip()
            if not line:
                continue
            try:
                events.append(json.loads(line))
            except json.JSONDecodeError:
                continue
    return events


def extract_retained_staging_session(receipt_path: Path, dest: Path) -> Optional[Path]:
    staging_root = dest / "_ingest_staging"
    for event in parse_ndjson_events(receipt_path):
        data = event.get("data", {})
        staging_path = data.get("staging_path")
        if not isinstance(staging_path, str):
            continue
        staging_file = Path(staging_path)
        if not staging_file.is_relative_to(staging_root):
            continue
        relative = staging_file.relative_to(staging_root)
        if not relative.parts:
            continue
        return staging_root / relative.parts[0]

    sessions = sorted(path for path in staging_root.glob("*") if path.is_dir())
    if sessions:
        return sessions[0]
    return None


def assert_success(summary: dict, label: str) -> None:
    if summary.get("status") != "completed":
        raise AssertionError(f"{label}: expected status=completed, got {summary.get('status')}")
    if summary.get("status_label") != "VERIFIED":
        raise AssertionError(f"{label}: expected status_label=VERIFIED, got {summary.get('status_label')}")
    if summary.get("counts", {}).get("errors") != 0:
        raise AssertionError(f"{label}: expected errors=0")


def run_crash_and_recover(binary: Path, source: Path, scenario_root: Path) -> None:
    dest = scenario_root / "dest"
    dest.mkdir(parents=True, exist_ok=True)
    receipts_dir = dest / "_ingest_receipts"
    source_before = file_manifest(source)

    args = [str(binary), "--source", str(source), "--dest", str(dest), "--json", "--max-parallel-copies", "1"]
    env = os.environ.copy()
    env["ROLLKEEP_TEST_SLEEP_BEFORE_COMMIT_SECONDS"] = "30"
    process = subprocess.Popen(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=env)

    receipt_path = wait_for_receipt_file(receipts_dir, timeout_seconds=30.0)
    wait_for_verified_before_commit(receipt_path, timeout_seconds=60.0)

    process.kill()
    stdout, stderr = process.communicate(timeout=15.0)
    if process.returncode == 0:
        raise AssertionError(f"expected non-zero exit after forced crash\nstdout:\n{stdout}\nstderr:\n{stderr}")

    crash_receipt_content = receipt_path.read_text(encoding="utf-8", errors="ignore")
    if '"event_type":"SESSION_STARTED"' not in crash_receipt_content:
        raise AssertionError("crash run receipt missing SESSION_STARTED")
    if '"event_type":"FILE_VERIFIED"' not in crash_receipt_content:
        raise AssertionError("crash run receipt missing FILE_VERIFIED")
    if '"event_type":"FILE_COMMIT_STARTED"' in crash_receipt_content:
        raise AssertionError("crash run should not reach FILE_COMMIT_STARTED")

    retained_staging_session = extract_retained_staging_session(receipt_path, dest)
    if retained_staging_session is None:
        raise AssertionError("unable to resolve retained staging session path from crash receipt")
    if not retained_staging_session.is_dir():
        raise AssertionError(f"retained staging session missing after crash: {retained_staging_session}")
    if not any(path.is_file() for path in retained_staging_session.rglob("*")):
        raise AssertionError(f"retained staging session has no files after crash: {retained_staging_session}")

    recovery_summary = run_rollkeep(binary, source, dest)
    assert_success(recovery_summary, "recovery run")
    if recovery_summary["counts"]["committed"] == 0:
        raise AssertionError("recovery run should commit files")

    if not retained_staging_session.exists():
        raise AssertionError("retained staging session from crash should remain available after recovery rerun")

    rerun_summary = run_rollkeep(binary, source, dest)
    assert_success(rerun_summary, "post-recovery rerun")
    if rerun_summary["counts"]["committed"] != 0:
        raise AssertionError("post-recovery rerun should not commit new files")
    if rerun_summary["counts"]["duplicate_not_copied"] == 0:
        raise AssertionError("post-recovery rerun should classify files as duplicates")
    if rerun_summary["idempotency"]["classification"] != "idempotent_rerun":
        raise AssertionError("post-recovery rerun should report idempotent_rerun")

    source_after = file_manifest(source)
    if source_before != source_after:
        raise AssertionError(f"{source.name} source fixture changed during crash/restart scenario")

    print(
        f"[pass] {source.name}: retained_staging={retained_staging_session}, "
        f"recovery_committed={recovery_summary['counts']['committed']}, "
        f"rerun_duplicates={rerun_summary['counts']['duplicate_not_copied']}"
    )


def main() -> int:
    parser = argparse.ArgumentParser(description="Run crash/restart recovery E2E checks.")
    parser.add_argument("--binary", required=True, help="Path to the rollkeep binary.")
    parser.add_argument("--repo-root", required=True, help="Repository root.")
    args = parser.parse_args()

    repo_root = Path(args.repo_root).resolve()
    binary = Path(args.binary).resolve()
    source = repo_root / "Tests" / "TestingDirs" / "SD_CARD1"
    if not source.is_dir():
        raise AssertionError(f"missing source fixture: {source}")

    with tempfile.TemporaryDirectory(prefix="rollkeep-e2e-crash-restart-") as workdir:
        run_crash_and_recover(binary=binary, source=source, scenario_root=Path(workdir))

    print("Crash/restart recovery E2E checks passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
