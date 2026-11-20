#!/usr/bin/env python3

import argparse
import json
import os
import signal
import subprocess
import sys
import tempfile
import time
from pathlib import Path


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


def wait_for_receipt_file(receipts_dir: Path, timeout_seconds: float) -> Path:
    deadline = time.monotonic() + timeout_seconds
    while time.monotonic() < deadline:
        receipts = sorted(receipts_dir.glob("*.ndjson"))
        if receipts:
            return receipts[0]
        time.sleep(0.05)
    raise AssertionError(f"timed out waiting for receipt file in {receipts_dir}")


def wait_for_verified_before_commit(receipt_path: Path, timeout_seconds: float) -> None:
    deadline = time.monotonic() + timeout_seconds
    while time.monotonic() < deadline:
        content = receipt_path.read_text(encoding="utf-8", errors="ignore")
        if '"event_type":"FILE_VERIFIED"' in content and '"event_type":"FILE_COMMIT_STARTED"' not in content:
            return
        time.sleep(0.05)
    raise AssertionError("timed out waiting for FILE_VERIFIED before commit")


def parse_ndjson_events(path: Path) -> list[dict]:
    events: list[dict] = []
    with path.open(encoding="utf-8") as handle:
        for line in handle:
            line = line.strip()
            if line:
                events.append(json.loads(line))
    return events


def verify_graceful_signal(binary: Path, source: Path, sig: int, sig_name: str) -> None:
    with tempfile.TemporaryDirectory(prefix=f"fyluro-e2e-signal-{sig_name.lower()}-") as workdir:
        dest = Path(workdir) / "dest"
        dest.mkdir(parents=True, exist_ok=True)
        receipts_dir = dest / "_ingest_receipts"

        env = os.environ.copy()
        env["FYLURO_TEST_SLEEP_BEFORE_COMMIT_SECONDS"] = "2"
        args = [str(binary), "--source", str(source), "--dest", str(dest), "--json", "--max-parallel-copies", "1"]

        process = subprocess.Popen(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=env)
        try:
            receipt_path = wait_for_receipt_file(receipts_dir, timeout_seconds=30.0)
            wait_for_verified_before_commit(receipt_path, timeout_seconds=60.0)

            process.send_signal(sig)
            stdout, stderr = process.communicate(timeout=15.0)
        except Exception:
            process.kill()
            process.wait()
            raise

        if process.returncode != 6:
            raise AssertionError(
                f"{sig_name}: expected commit-phase abort exit code 6, got {process.returncode}\n"
                f"stdout:\n{stdout}\nstderr:\n{stderr}"
            )

        if sig_name not in stderr:
            raise AssertionError(f"{sig_name}: expected stderr notice mentioning {sig_name}\nstderr:\n{stderr}")

        summary = parse_final_json(stdout, stderr)
        if summary.get("status") != "aborted":
            raise AssertionError(f"{sig_name}: expected status=aborted, got {summary.get('status')}")
        if summary.get("status_label") != "FAILED":
            raise AssertionError(f"{sig_name}: expected status_label=FAILED, got {summary.get('status_label')}")
        failure_info = summary.get("failure", {})
        if failure_info.get("phase") != "commit":
            raise AssertionError(f"{sig_name}: expected failure.phase=commit, got {failure_info}")
        if "cancelled" not in str(failure_info.get("reason", "")).lower():
            raise AssertionError(f"{sig_name}: expected cancellation reason, got {failure_info}")
        if summary.get("counts", {}).get("committed") != 0:
            raise AssertionError(f"{sig_name}: expected committed=0, got {summary.get('counts')}")

        events = parse_ndjson_events(receipt_path)
        event_types = [event.get("event_type") for event in events]
        for required in ("SESSION_STARTED", "FILE_VERIFIED", "ERROR", "SUMMARY", "SESSION_FINISHED"):
            if required not in event_types:
                raise AssertionError(f"{sig_name}: receipt missing {required}; got {event_types}")

        summary_events = [event for event in events if event.get("event_type") == "SUMMARY"]
        if summary_events[-1].get("data", {}).get("verified_ok") is not False:
            raise AssertionError(f"{sig_name}: expected SUMMARY verified_ok=false, got {summary_events[-1]}")

        finished_events = [event for event in events if event.get("event_type") == "SESSION_FINISHED"]
        if finished_events[-1].get("data", {}).get("status") != "aborted":
            raise AssertionError(f"{sig_name}: SESSION_FINISHED status != aborted")

        staging_root = dest / "_ingest_staging"
        staging_sessions = [path for path in staging_root.iterdir() if path.is_dir()] if staging_root.is_dir() else []
        if not staging_sessions:
            raise AssertionError(f"{sig_name}: expected retained staging session under {staging_root} (I-7)")
        if not any(path.is_file() for path in staging_sessions[0].rglob("*")):
            raise AssertionError(f"{sig_name}: retained staging session has no files")

        committed_files = [
            path for path in dest.rglob("*")
            if path.is_file()
            and "_ingest_staging" not in path.parts
            and "_ingest_receipts" not in path.parts
        ]
        if committed_files:
            raise AssertionError(f"{sig_name}: expected no committed library files, found {committed_files}")

        print(f"[pass] {sig_name}: aborted receipt written, staging retained, exit=6")


def verify_second_signal_force_exit(binary: Path, source: Path) -> None:
    with tempfile.TemporaryDirectory(prefix="fyluro-e2e-double-signal-") as workdir:
        dest = Path(workdir) / "dest"
        dest.mkdir(parents=True, exist_ok=True)
        receipts_dir = dest / "_ingest_receipts"

        env = os.environ.copy()
        env["FYLURO_TEST_SLEEP_BEFORE_COMMIT_SECONDS"] = "30"
        args = [str(binary), "--source", str(source), "--dest", str(dest), "--json", "--max-parallel-copies", "1"]

        process = subprocess.Popen(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=env)
        try:
            receipt_path = wait_for_receipt_file(receipts_dir, timeout_seconds=30.0)
            wait_for_verified_before_commit(receipt_path, timeout_seconds=60.0)

            started_wait = time.monotonic()
            process.send_signal(signal.SIGTERM)
            time.sleep(0.2)
            process.send_signal(signal.SIGTERM)
            stdout, stderr = process.communicate(timeout=5.0)
            elapsed = time.monotonic() - started_wait
        except Exception:
            process.kill()
            process.wait()
            raise

        expected_code = 128 + int(signal.SIGTERM)
        if process.returncode != expected_code:
            raise AssertionError(
                f"double SIGTERM: expected exit code {expected_code}, got {process.returncode}\n"
                f"stdout:\n{stdout}\nstderr:\n{stderr}"
            )
        if elapsed >= 5.0:
            raise AssertionError(f"double SIGTERM took too long ({elapsed:.2f}s)")

        print(f"[pass] double SIGTERM: exited immediately in {elapsed:.2f}s with code {process.returncode}")


def main() -> int:
    parser = argparse.ArgumentParser(description="Run CLI signal cancellation E2E checks.")
    parser.add_argument("--binary", required=True, help="Path to the fyluro binary.")
    parser.add_argument("--repo-root", required=True, help="Repository root.")
    args = parser.parse_args()

    binary = Path(args.binary).resolve()
    source = Path(args.repo_root).resolve() / "Tests" / "TestingDirs" / "SD_CARD1"
    if not source.is_dir():
        raise AssertionError(f"missing source fixture: {source}")

    for sig, name in (
        (signal.SIGINT, "SIGINT"),
        (signal.SIGTERM, "SIGTERM"),
        (signal.SIGHUP, "SIGHUP"),
    ):
        verify_graceful_signal(binary=binary, source=source, sig=sig, sig_name=name)

    verify_second_signal_force_exit(binary=binary, source=source)
    print("CLI signal cancellation E2E checks passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
