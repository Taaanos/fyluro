#!/usr/bin/env python3

import argparse
import json
import os
import sys
from collections import Counter, defaultdict
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Dict, List, Optional, Sequence, Tuple

BLOCKS = " ░▒▓█"
SPARK = "▁▂▃▄▅▆▇█"
WEEKDAY_LABELS = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]


@dataclass
class SessionRecord:
    session_id: str
    receipt_path: Path
    started_at: Optional[datetime]
    dry_run: bool
    film_mode_used: bool
    complete: bool
    photos: int = 0
    videos: int = 0
    bytes_processed: int = 0
    committed: int = 0
    errors: int = 0
    duplicates: int = 0
    conflicts_renamed: int = 0
    verified: int = 0
    candidate_count: int = 0
    known_camera_files: int = 0
    unknown_camera_files: int = 0
    camera_counts: Dict[str, int] = field(default_factory=dict)
    phase_timings_ms: Dict[str, int] = field(default_factory=dict)
    total_duration_ms: int = 0


def find_receipt_files(paths: Sequence[str]) -> List[Path]:
    found: List[Path] = []
    for raw in paths:
        root = Path(raw).expanduser()
        if not root.exists():
            print(f"warning: path does not exist, skipping: {root}", file=sys.stderr)
            continue
        if root.is_file() and root.suffix == ".ndjson":
            found.append(root)
            continue
        if root.name == "_ingest_receipts":
            found.extend(sorted(root.glob("*.ndjson")))
            continue
        for receipts_dir in root.rglob("_ingest_receipts"):
            found.extend(sorted(receipts_dir.glob("*.ndjson")))
    seen = set()
    unique: List[Path] = []
    for p in found:
        resolved = p.resolve()
        if resolved not in seen:
            seen.add(resolved)
            unique.append(p)
    return unique


def parse_timestamp(raw: Optional[str]) -> Optional[datetime]:
    if not raw:
        return None
    try:
        return datetime.fromisoformat(raw.replace("Z", "+00:00"))
    except ValueError:
        return None


def parse_receipt(path: Path) -> Optional[SessionRecord]:
    events = []
    try:
        with path.open() as handle:
            for line in handle:
                line = line.strip()
                if not line:
                    continue
                try:
                    events.append(json.loads(line))
                except json.JSONDecodeError:
                    print(f"warning: skipping malformed line in {path}", file=sys.stderr)
    except OSError as error:
        print(f"warning: unable to read {path}: {error}", file=sys.stderr)
        return None

    if not events:
        return None

    started_event = next((e for e in events if e.get("event_type") == "SESSION_STARTED"), None)
    summary_event = next((e for e in reversed(events) if e.get("event_type") == "SUMMARY"), None)

    session_id = (started_event or events[0]).get("session_id", path.stem)
    started_at = parse_timestamp((started_event or events[0]).get("timestamp"))
    started_data = (started_event or {}).get("data", {})

    record = SessionRecord(
        session_id=session_id,
        receipt_path=path,
        started_at=started_at,
        dry_run=bool(started_data.get("dry_run", False)),
        film_mode_used=bool(started_data.get("film_mode", {}).get("used", False)),
        complete=summary_event is not None,
    )

    if summary_event is None:
        return record

    data = summary_event.get("data", {})
    totals_outcome = data.get("totals_by_outcome", {})
    totals_media = data.get("totals_by_media_type", {})
    analysis = data.get("analysis", {})

    record.photos = int(totals_media.get("photos", 0))
    record.videos = int(totals_media.get("videos", 0))
    record.bytes_processed = int(data.get("bytes_processed", 0))
    record.committed = int(totals_outcome.get("committed", 0))
    record.errors = int(totals_outcome.get("errors", 0))
    record.duplicates = int(totals_outcome.get("duplicate_not_copied", 0))
    record.conflicts_renamed = int(totals_outcome.get("conflicts_renamed", 0))
    record.verified = int(totals_outcome.get("verified", 0))
    record.candidate_count = int(analysis.get("candidate_file_count", record.photos + record.videos))
    record.known_camera_files = int(data.get("known_camera_file_count", 0))
    record.unknown_camera_files = int(data.get("unknown_camera_file_count", 0))
    record.total_duration_ms = int(analysis.get("total_duration_ms", 0))

    for entry in data.get("camera_labels", []):
        label = str(entry.get("label", "unknown"))
        record.camera_counts[label] = record.camera_counts.get(label, 0) + int(entry.get("file_count", 0))

    for entry in analysis.get("phase_timings_ms", []):
        phase = str(entry.get("phase", "?"))
        record.phase_timings_ms[phase] = record.phase_timings_ms.get(phase, 0) + int(entry.get("milliseconds", 0))

    return record


def human_bytes(count: float) -> str:
    value = float(count)
    for unit in ["B", "KB", "MB", "GB", "TB"]:
        if value < 1024 or unit == "TB":
            return f"{value:.1f} {unit}" if unit != "B" else f"{int(value)} {unit}"
        value /= 1024
    return f"{value:.1f} TB"


def sparkline(values: Sequence[float]) -> str:
    if not values:
        return ""
    lo, hi = min(values), max(values)
    if hi == lo:
        return SPARK[0] * len(values)
    span = hi - lo
    out = []
    for v in values:
        idx = int((v - lo) / span * (len(SPARK) - 1))
        out.append(SPARK[idx])
    return "".join(out)


def render_calendar(day_counts: Dict[str, int], end_date: datetime, weeks: int = 52) -> str:
    end = end_date.date()
    start = end - timedelta(days=weeks * 7 - 1)
    start -= timedelta(days=start.weekday())  # align to Monday

    values = [v for v in day_counts.values() if v > 0]
    if values:
        sorted_vals = sorted(values)
        thresholds = [
            sorted_vals[int(len(sorted_vals) * q) - 1] if sorted_vals else 0
            for q in (0.25, 0.5, 0.75, 1.0)
        ]
    else:
        thresholds = [0, 0, 0, 0]

    def shade(count: int) -> str:
        if count <= 0:
            return BLOCKS[0]
        for i, threshold in enumerate(thresholds):
            if count <= threshold:
                return BLOCKS[i + 1]
        return BLOCKS[-1]

    total_days = (end - start).days + 1
    total_weeks = (total_days + 6) // 7

    rows = []
    for weekday in range(7):
        cells = []
        for week in range(total_weeks):
            day = start + timedelta(days=week * 7 + weekday)
            if day > end:
                cells.append(" ")
                continue
            cells.append(shade(day_counts.get(day.isoformat(), 0)))
        rows.append(f"{WEEKDAY_LABELS[weekday]}  {' '.join(cells)}")

    month_labels = [" "] * total_weeks
    last_month = None
    for week in range(total_weeks):
        day = start + timedelta(days=week * 7)
        if day.month != last_month and day <= end:
            month_labels[week] = day.strftime("%b")
            last_month = day.month
    month_header = "    " + " ".join(m[0] if len(m) == 1 else m.ljust(1) for m in month_labels)

    legend = f"less {BLOCKS[0]}{BLOCKS[1]}{BLOCKS[2]}{BLOCKS[3]}{BLOCKS[4]} more"
    return "\n".join(rows) + "\n" + legend


def compute_streaks(active_days: Sequence[str]) -> Tuple[int, int]:
    if not active_days:
        return 0, 0
    days = sorted(datetime.fromisoformat(d).date() for d in active_days)
    longest = current = 1
    for prev, curr in zip(days, days[1:]):
        if (curr - prev).days == 1:
            current += 1
            longest = max(longest, current)
        elif (curr - prev).days > 1:
            current = 1
    today = datetime.now(timezone.utc).date()
    running = 0
    cursor = today
    day_set = set(days)
    while cursor in day_set:
        running += 1
        cursor -= timedelta(days=1)
    return longest, running


def build_report(records: List[SessionRecord], top_cameras: int) -> dict:
    complete = [r for r in records if r.complete]
    real_runs = [r for r in complete if not r.dry_run]

    day_counts: Dict[str, int] = defaultdict(int)
    month_bytes: Dict[str, int] = defaultdict(int)
    month_camera_counts: Dict[str, Counter] = defaultdict(Counter)
    camera_totals: Counter = Counter()
    weekday_counts: Counter = Counter()

    for r in real_runs:
        if r.started_at is None:
            continue
        day_key = r.started_at.date().isoformat()
        day_counts[day_key] += r.candidate_count or 1
        month_key = r.started_at.strftime("%Y-%m")
        month_bytes[month_key] += r.bytes_processed
        weekday_counts[r.started_at.strftime("%A")] += 1
        for label, count in r.camera_counts.items():
            month_camera_counts[month_key][label] += count
            camera_totals[label] += count

    months_sorted = sorted(month_bytes.keys())
    cumulative = 0
    cumulative_by_month = {}
    for m in months_sorted:
        cumulative += month_bytes[m]
        cumulative_by_month[m] = cumulative

    total_errors = sum(r.errors for r in real_runs)
    total_duplicates = sum(r.duplicates for r in real_runs)
    total_candidates = sum(r.candidate_count for r in real_runs)
    total_known = sum(r.known_camera_files for r in real_runs)
    total_unknown = sum(r.unknown_camera_files for r in real_runs)

    error_sessions = sorted(
        (r for r in real_runs if r.errors > 0),
        key=lambda r: r.errors,
        reverse=True,
    )

    perf_series = [
        (r.started_at, r.total_duration_ms / r.candidate_count)
        for r in real_runs
        if r.started_at and r.candidate_count > 0
    ]
    perf_series.sort(key=lambda pair: pair[0])

    longest_streak, current_streak = compute_streaks(list(day_counts.keys()))

    busiest_day = max(day_counts.items(), key=lambda kv: kv[1], default=(None, 0))

    incomplete_count = len(records) - len(complete)
    dry_run_count = len(complete) - len(real_runs)

    return {
        "session_count": len(records),
        "incomplete_session_count": incomplete_count,
        "dry_run_count": dry_run_count,
        "real_run_count": len(real_runs),
        "date_range": [
            min((r.started_at for r in real_runs if r.started_at), default=None),
            max((r.started_at for r in real_runs if r.started_at), default=None),
        ],
        "total_bytes": sum(r.bytes_processed for r in real_runs),
        "total_committed": sum(r.committed for r in real_runs),
        "total_candidates": total_candidates,
        "total_errors": total_errors,
        "total_duplicates": total_duplicates,
        "known_camera_files": total_known,
        "unknown_camera_files": total_unknown,
        "day_counts": dict(day_counts),
        "month_bytes": dict(month_bytes),
        "cumulative_by_month": cumulative_by_month,
        "month_camera_counts": {m: dict(c) for m, c in month_camera_counts.items()},
        "camera_totals": dict(camera_totals.most_common(top_cameras)),
        "camera_other_total": sum(
            count for label, count in camera_totals.items()
            if label not in dict(camera_totals.most_common(top_cameras))
        ),
        "weekday_counts": dict(weekday_counts),
        "busiest_day": busiest_day,
        "longest_streak": longest_streak,
        "current_streak": current_streak,
        "error_sessions": [
            {"session_id": r.session_id, "path": str(r.receipt_path), "errors": r.errors,
             "started_at": r.started_at.isoformat() if r.started_at else None}
            for r in error_sessions[:10]
        ],
        "perf_series": [(t.isoformat(), ms) for t, ms in perf_series],
    }


def render_text_report(report: dict) -> str:
    lines: List[str] = []
    add = lines.append

    start, end = report["date_range"]
    add("=" * 60)
    add("Fyluro Ingest Receipt Insights")
    add("=" * 60)
    if start and end:
        add(f"Coverage: {start.date()} to {end.date()}")
    add(
        f"Sessions: {report['real_run_count']} real, {report['dry_run_count']} dry-run, "
        f"{report['incomplete_session_count']} incomplete/crashed"
    )
    add(f"Files committed: {report['total_committed']}  ({human_bytes(report['total_bytes'])})")
    add("")

    add("Activity calendar (candidate files scanned per day)")
    add("-" * 60)
    if start:
        add(render_calendar(report["day_counts"], end or datetime.now(timezone.utc)))
    else:
        add("(no non-dry-run sessions found)")
    if report["busiest_day"][0]:
        add(f"Busiest day: {report['busiest_day'][0]} ({report['busiest_day'][1]} files)")
    add(f"Longest streak: {report['longest_streak']} day(s)   Current streak: {report['current_streak']} day(s)")
    if report["weekday_counts"]:
        top_weekday = max(report["weekday_counts"].items(), key=lambda kv: kv[1])
        add(f"Most common ingest day: {top_weekday[0]} ({top_weekday[1]} sessions)")
    add("")

    add("Camera usage (top cameras by file count)")
    add("-" * 60)
    camera_totals = report["camera_totals"]
    if camera_totals:
        max_count = max(camera_totals.values())
        for label, count in camera_totals.items():
            bar_len = int(count / max_count * 30) if max_count else 0
            add(f"{label:<16} {'█' * bar_len:<30} {count}")
        if report["camera_other_total"]:
            add(f"{'(other)':<16} {'':<30} {report['camera_other_total']}")
    else:
        add("(no camera data)")
    add("")

    add("Library growth (cumulative bytes processed, monthly)")
    add("-" * 60)
    months = sorted(report["cumulative_by_month"].keys())
    if months:
        values = [report["cumulative_by_month"][m] for m in months]
        add(sparkline(values))
        add(f"{months[0]} -> {months[-1]}: {human_bytes(values[0])} -> {human_bytes(values[-1])}")
    else:
        add("(no data)")
    add("")

    add("Reliability")
    add("-" * 60)
    total_candidates = report["total_candidates"] or 1
    error_rate = report["total_errors"] / total_candidates * 100
    dup_rate = report["total_duplicates"] / total_candidates * 100
    known = report["known_camera_files"]
    unknown = report["unknown_camera_files"]
    known_total = known + unknown
    add(f"Errors: {report['total_errors']} ({error_rate:.2f}% of candidates)")
    add(f"Duplicates skipped: {report['total_duplicates']} ({dup_rate:.2f}% of candidates)")
    if known_total:
        add(f"Unknown-camera files: {unknown} ({unknown / known_total * 100:.1f}%)")
    if report["error_sessions"]:
        add("Sessions with the most errors:")
        for entry in report["error_sessions"][:5]:
            add(f"  - {entry['started_at']}  {entry['errors']} error(s)  {entry['path']}")
    add("")

    add("Performance trend (ms per candidate file, chronological)")
    add("-" * 60)
    perf = report["perf_series"]
    if len(perf) >= 2:
        values = [ms for _, ms in perf]
        add(sparkline(values))
        midpoint = len(values) // 2
        first_half_avg = sum(values[:midpoint]) / midpoint if midpoint else values[0]
        second_half_avg = sum(values[midpoint:]) / (len(values) - midpoint)
        drift = (second_half_avg - first_half_avg) / first_half_avg * 100 if first_half_avg else 0
        direction = "slower" if drift > 0 else "faster"
        add(f"Recent sessions are {abs(drift):.0f}% {direction} per file than earlier ones "
            f"({first_half_avg:.1f}ms -> {second_half_avg:.1f}ms)")
    else:
        add("(not enough sessions to show a trend)")

    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Aggregate insights from Fyluro _ingest_receipts NDJSON receipts."
    )
    parser.add_argument(
        "paths",
        nargs="+",
        help="One or more paths: a _ingest_receipts directory, a single .ndjson file, "
        "or a root directory to search recursively for _ingest_receipts folders.",
    )
    parser.add_argument("--top-cameras", type=int, default=6, help="Number of cameras to show individually.")
    parser.add_argument("--json", action="store_true", help="Emit the aggregated insights as JSON instead of text.")
    args = parser.parse_args()

    receipt_files = find_receipt_files(args.paths)
    if not receipt_files:
        print("No .ndjson receipts found under the given path(s).", file=sys.stderr)
        return 1

    records = []
    for path in receipt_files:
        record = parse_receipt(path)
        if record is not None:
            records.append(record)

    if not records:
        print("Found receipt files but none could be parsed.", file=sys.stderr)
        return 1

    report = build_report(records, top_cameras=args.top_cameras)

    if args.json:
        def default(value):
            if isinstance(value, datetime):
                return value.isoformat()
            raise TypeError(f"unserializable type: {type(value)}")

        print(json.dumps(report, indent=2, default=default))
    else:
        print(render_text_report(report))

    return 0


if __name__ == "__main__":
    sys.exit(main())
