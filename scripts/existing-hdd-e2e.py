#!/usr/bin/env python3

import argparse
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional, Sequence, Tuple


AUGMENTED_CAPTURE_DATETIME = datetime(2024, 12, 15, 12, 0, 0, tzinfo=timezone.utc)
AUGMENTED_CAPTURE_TIMESTAMP = AUGMENTED_CAPTURE_DATETIME.timestamp()
PHOTO_COMPRESSION_SEGMENTS = {"RAW", "Non-RAW"}
SIDECAR_EXTENSIONS = {"thm", "xmp", "aae", "xml", "srt", "cpi", "nksc", "dop", "pp3", "json"}
KNOWN_CAMERA_LABEL = "ilce-7cm2"
FORCED_MISSING_CAPTURE_DATE_PATHS: Tuple[str, ...] = (
    "DCIM/E2E_UNSORTED.JPG",
    "PRIVATE/E2E_UNSORTED.MP4",
)
AUGMENTED_FILES: Dict[str, bytes] = {
    "DCIM/E2E_RAW.CR3": b"rollkeep-e2e-raw-photo-bytes\n",
    "DCIM/E2E_RAW.XMP": b"<x:xmpmeta>raw-sidecar</x:xmpmeta>\n",
    "DCIM/E2E_STD.JPG": b"rollkeep-e2e-standard-photo-bytes\n",
    "DCIM/E2E_STD.XMP": b"<x:xmpmeta>standard-sidecar</x:xmpmeta>\n",
    "PRIVATE/E2E_VID.MP4": b"rollkeep-e2e-video-bytes\n",
    "PRIVATE/E2E_VID.XML": b"<Metadata><Clip>E2E_VID</Clip></Metadata>\n",
    "PRIVATE/E2E_KNOWN.MP4": b"rollkeep-e2e-known-video-bytes\n",
    "PRIVATE/E2E_KNOWNM01.XML": (
        b"<NonRealTimeMeta>"
        b"<CreationDate value=\"2024-12-15T12:00:00+00:00\"/>"
        b"<Device manufacturer=\"Sony\" modelName=\"ILCE-7CM2\" serialNo=\"4294967295\"/>"
        b"</NonRealTimeMeta>\n"
    ),
    "DCIM/E2E_UNSORTED.JPG": b"rollkeep-e2e-unsorted-photo-bytes\n",
    "PRIVATE/E2E_UNSORTED.MP4": b"rollkeep-e2e-unsorted-video-bytes\n",
    "PRIVATE/E2E_UNSORTED.XML": b"<Metadata><Clip>E2E_UNSORTED</Clip></Metadata>\n",
}


@dataclass(frozen=True)
class SourceConfig:
    label: str
    source_dir: Path
    baseline_fixture: Path
    duplicate_fixture: Path
    conflict_fixture: Path


@dataclass(frozen=True)
class PathSchemeConfig:
    slug: str
    chronological_layout: str
    include_camera_folder: bool
    split_photo_compression: bool
    cli_args: Sequence[str]


@dataclass(frozen=True)
class Scenario:
    name: str
    source_key: str
    fixture_dirs: Sequence[Path]
    duplicate_sources: Sequence[str]
    conflict_sources: Sequence[str]
    path_scheme: PathSchemeConfig
    seed_all_duplicates: bool = False
    rerun: bool = False
    augment_source: bool = False
    forced_missing_capture_date_paths: Sequence[str] = ()


PATH_SCHEMES: Sequence[PathSchemeConfig] = [
    PathSchemeConfig(
        slug="default-yyyymm-camera-nosplit",
        chronological_layout="YYYY/YYYYMM",
        include_camera_folder=True,
        split_photo_compression=False,
        cli_args=(),
    ),
    PathSchemeConfig(
        slug="yyyy-mm-camera-nosplit",
        chronological_layout="YYYY/MM",
        include_camera_folder=True,
        split_photo_compression=False,
        cli_args=("--path-chronological", "YYYY/MM"),
    ),
    PathSchemeConfig(
        slug="yyyymm-no-camera-nosplit",
        chronological_layout="YYYY/YYYYMM",
        include_camera_folder=False,
        split_photo_compression=False,
        cli_args=("--path-no-camera",),
    ),
    PathSchemeConfig(
        slug="yyyymm-camera-split-raw",
        chronological_layout="YYYY/YYYYMM",
        include_camera_folder=True,
        split_photo_compression=True,
        cli_args=("--path-split-raw",),
    ),
    PathSchemeConfig(
        slug="yyyy-mm-no-camera-nosplit",
        chronological_layout="YYYY/MM",
        include_camera_folder=False,
        split_photo_compression=False,
        cli_args=("--path-chronological", "YYYY/MM", "--path-no-camera"),
    ),
    PathSchemeConfig(
        slug="yyyy-mm-camera-split-raw",
        chronological_layout="YYYY/MM",
        include_camera_folder=True,
        split_photo_compression=True,
        cli_args=("--path-chronological", "YYYY/MM", "--path-split-raw"),
    ),
    PathSchemeConfig(
        slug="yyyymm-no-camera-split-raw",
        chronological_layout="YYYY/YYYYMM",
        include_camera_folder=False,
        split_photo_compression=True,
        cli_args=("--path-no-camera", "--path-split-raw"),
    ),
    PathSchemeConfig(
        slug="yyyy-mm-no-camera-split-raw",
        chronological_layout="YYYY/MM",
        include_camera_folder=False,
        split_photo_compression=True,
        cli_args=("--path-chronological", "YYYY/MM", "--path-no-camera", "--path-split-raw"),
    ),
]
DEFAULT_PATH_SCHEME = PATH_SCHEMES[0]


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def file_manifest(root: Path) -> Dict[str, Dict[str, object]]:
    manifest: Dict[str, Dict[str, object]] = {}
    for path in sorted(p for p in root.rglob("*") if p.is_file()):
        stat = path.stat()
        manifest[str(path.relative_to(root))] = {
            "sha256": sha256_file(path),
            "size": stat.st_size,
            "mtime_ns": stat.st_mtime_ns,
        }
    return manifest


def path_state(root: Path) -> Dict[str, Dict[str, object]]:
    state: Dict[str, Dict[str, object]] = {}
    for path in sorted(p for p in root.rglob("*") if p.is_file()):
        stat = path.stat()
        state[str(path.relative_to(root))] = {
            "sha256": sha256_file(path),
            "mtime_ns": stat.st_mtime_ns,
            "size": stat.st_size,
        }
    return state


def library_state(root: Path) -> Dict[str, Dict[str, object]]:
    state = path_state(root)
    return {
        relative_path: payload
        for relative_path, payload in state.items()
        if not relative_path.startswith("_ingest_receipts/")
        and not relative_path.startswith("_ingest_staging/")
    }


def copy_tree_contents(source: Path, dest: Path) -> None:
    if not source.exists():
        return
    for path in sorted(source.rglob("*")):
        relative = path.relative_to(source)
        target = dest / relative
        if path.is_dir():
            target.mkdir(parents=True, exist_ok=True)
            continue
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(path, target)


def load_fixture(fixture_dir: Path) -> Dict[str, List[str]]:
    with (fixture_dir / "fixture.json").open() as handle:
        payload = json.load(handle)
    return {
        "duplicate_source_paths": payload.get("duplicate_source_paths", []),
        "conflict_source_paths": payload.get("conflict_source_paths", []),
    }


def run_rollkeep(
    binary: Path,
    source: Path,
    dest: Path,
    extra_args: Optional[Sequence[str]] = None,
    env_overrides: Optional[Dict[str, str]] = None,
) -> dict:
    args = [str(binary), "--source", str(source), "--dest", str(dest), "--json"]
    if extra_args:
        args.extend(extra_args)

    env = os.environ.copy()
    if env_overrides:
        env.update(env_overrides)

    result = subprocess.run(args, capture_output=True, text=True, env=env)
    if result.returncode != 0:
        raise AssertionError(
            f"rollkeep failed with exit code {result.returncode}\nstdout:\n{result.stdout}\nstderr:\n{result.stderr}"
        )

    lines = result.stdout.splitlines()
    for index, line in enumerate(lines):
        if not line.lstrip().startswith("{"):
            continue
        candidate = "\n".join(lines[index:])
        try:
            return json.loads(candidate)
        except json.JSONDecodeError:
            continue

    raise AssertionError(f"unable to parse rollkeep JSON summary\nstdout:\n{result.stdout}\nstderr:\n{result.stderr}")


def plan_files(
    binary: Path,
    source: Path,
    scratch_root: Path,
    extra_args: Optional[Sequence[str]] = None,
    env_overrides: Optional[Dict[str, str]] = None,
) -> Tuple[Dict[str, str], Dict[str, str]]:
    dest = scratch_root / "planning-dest"
    dry_run_args = list(extra_args or []) + ["--dry-run"]
    summary = run_rollkeep(binary, source, dest, extra_args=dry_run_args, env_overrides=env_overrides)
    receipt_path = Path(summary["receipt"]["path"])
    plan_mapping: Dict[str, str] = {}
    source_hashes: Dict[str, str] = {}

    with receipt_path.open() as handle:
        for line in handle:
            event = json.loads(line)
            if event["event_type"] == "PLAN_COMPUTED":
                for file_entry in event["data"]["files"]:
                    final_relative = Path(file_entry["final_path"]).relative_to(dest)
                    plan_mapping[file_entry["path"]] = str(final_relative)
            if event["event_type"] == "SCAN_FILE_LIST":
                for file_entry in event["data"]["files"]:
                    source_path = source / file_entry["path"]
                    source_hashes[file_entry["path"]] = sha256_file(source_path)

    if not plan_mapping:
        raise AssertionError(f"missing PLAN_COMPUTED event for {source}")

    for source_relative in plan_mapping.keys():
        source_hashes.setdefault(source_relative, sha256_file(source / source_relative))

    shutil.rmtree(dest, ignore_errors=True)
    return plan_mapping, source_hashes


def final_relative_path(plan_mapping: Dict[str, str], source_relative_path: str) -> Path:
    return Path(plan_mapping[source_relative_path])


def path_with_suffix(relative_path: Path, suffix: int) -> Path:
    stem = relative_path.stem
    suffix_name = f"{stem}-{suffix}{relative_path.suffix}"
    return relative_path.with_name(suffix_name)


def parse_receipt_events(path: Path) -> List[dict]:
    with path.open() as handle:
        return [json.loads(line) for line in handle]


def summary_event(events: Sequence[dict]) -> dict:
    for event in reversed(events):
        if event["event_type"] == "SUMMARY":
            return event["data"]
    raise AssertionError("missing SUMMARY event")


def path_scheme_string(path_scheme: PathSchemeConfig) -> str:
    def template(chronological_component: str) -> str:
        components = [chronological_component]
        if path_scheme.include_camera_folder:
            components.append("<Camera>")
        components.append("<Photos|Videos>")
        if path_scheme.split_photo_compression:
            components.append("<RAW|Non-RAW (Photos)>")
        components.append("<filename>")
        return "/".join(components)

    return f"{template(path_scheme.chronological_layout)} ; {template('_unsorted')}"


def event_data(events: Sequence[dict], event_type: str) -> Dict[str, Any]:
    for event in events:
        if event["event_type"] == event_type:
            payload = event.get("data")
            if not isinstance(payload, dict):
                raise AssertionError(f"{event_type} event data missing or malformed")
            return payload
    raise AssertionError(f"missing {event_type} event")


def assert_path_scheme_events(events: Sequence[dict], path_scheme: PathSchemeConfig) -> None:
    expected = path_scheme_string(path_scheme)
    for event_type in ["SESSION_STARTED", "PLAN_COMPUTED", "SUMMARY"]:
        data = event_data(events, event_type)
        actual = data.get("path_scheme")
        if actual != expected:
            raise AssertionError(f"{event_type} path_scheme mismatch: {actual} != {expected}")


def assert_event_presence(
    events: Sequence[dict],
    expected_copied: int,
    expected_committed: int,
    expected_duplicates: int,
    expected_conflicts: int,
) -> None:
    required = ["SESSION_STARTED", "SCAN_SUMMARY", "CAMERA_LABEL_DETECTED", "PLAN_COMPUTED", "SESSION_FINISHED"]
    if expected_copied > 0:
        required.extend(["DIR_CREATED", "FILE_COPY_STARTED", "FILE_COPIED", "FILE_VERIFY_STARTED", "FILE_VERIFIED"])
    if expected_committed > 0:
        required.extend(["FILE_COMMIT_STARTED", "FILE_COMMITTED"])
    if expected_duplicates > 0:
        required.append("DUPLICATE_SKIPPED")
    if expected_conflicts > 0:
        required.append("CONFLICT_RENAMED")

    present = {event["event_type"] for event in events}
    missing = [event_type for event_type in required if event_type not in present]
    if missing:
        raise AssertionError(f"missing receipt events: {missing}")


def assert_touched_paths(summary_payload: dict, dest: Path, source: Path) -> None:
    touched = summary_payload["touched_paths"]
    receipt_fallback_prefix = str(Path(tempfile.gettempdir()) / "rollkeep" / "_ingest_receipts")

    for key in [
        "created_directories",
        "planned_final_files",
        "planned_staging_files",
        "written_final_files",
        "written_staging_files",
        "deleted_paths",
    ]:
        for value in touched.get(key, []):
            if not value.startswith(str(dest)):
                raise AssertionError(f"{key} escaped destination root: {value}")
            if value.startswith(str(source)):
                raise AssertionError(f"{key} incorrectly touched source root: {value}")

    for move_key in ["move_operations", "planned_move_operations"]:
        for entry in touched.get(move_key, []):
            if not entry["from"].startswith(str(dest)) or not entry["to"].startswith(str(dest)):
                raise AssertionError(f"{move_key} escaped destination root: {entry}")

    for receipt_path in touched.get("written_receipt_files", []):
        if receipt_path.startswith(str(dest)):
            continue
        if receipt_path.startswith(receipt_fallback_prefix):
            continue
        raise AssertionError(f"receipt write escaped allowed roots: {receipt_path}")


def assert_source_unchanged(expected_manifest: dict, source_dir: Path) -> None:
    actual_manifest = file_manifest(source_dir)
    if actual_manifest != expected_manifest:
        raise AssertionError(f"source tree changed for {source_dir}")


def ensure_parent(path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)


def prepare_destination(
    dest: Path,
    fixture_dirs: Sequence[Path],
    source_dir: Path,
    plan_mapping: Dict[str, str],
    duplicate_sources: Sequence[str],
    conflict_sources: Sequence[str],
    seed_all_duplicates: bool,
) -> Dict[str, Dict[str, object]]:
    for fixture_dir in fixture_dirs:
        copy_tree_contents(fixture_dir / "seed", dest)

    duplicate_candidates = list(plan_mapping.keys()) if seed_all_duplicates else list(duplicate_sources)
    for relative_path in duplicate_candidates:
        final_relative = final_relative_path(plan_mapping, relative_path)
        target = dest / final_relative
        ensure_parent(target)
        shutil.copy2(source_dir / relative_path, target)

    for relative_path in conflict_sources:
        final_relative = final_relative_path(plan_mapping, relative_path)
        target = dest / final_relative
        ensure_parent(target)
        target.write_text(f"preexisting conflict bytes for {relative_path}\n", encoding="utf-8")

    return path_state(dest)


def assert_preseeded_files_unchanged(before: Dict[str, Dict[str, object]], dest: Path) -> None:
    after = path_state(dest)
    for relative_path, state in before.items():
        actual = after.get(relative_path)
        if actual != state:
            raise AssertionError(f"preseeded file changed unexpectedly: {relative_path}")


def assert_no_sibling_writes(before: Dict[str, Dict[str, object]], root: Path, dest: Path) -> None:
    after = path_state(root)
    before_keys = set(before.keys())
    after_keys = set(after.keys())
    changed = set()

    for key in before_keys | after_keys:
        if before.get(key) != after.get(key):
            changed.add(key)

    escaped = []
    for relative in changed:
        absolute = root / relative
        if not absolute.is_relative_to(dest):
            escaped.append(relative)
    if escaped:
        raise AssertionError(f"writes escaped destination-adjacent workspace: {escaped}")


def assert_expected_final_files(
    source_dir: Path,
    dest: Path,
    plan_mapping: Dict[str, str],
    source_hashes: Dict[str, str],
    duplicate_sources: Sequence[str],
    conflict_sources: Sequence[str],
    preseeded_state: Dict[str, Dict[str, object]],
) -> None:
    duplicate_set = set(duplicate_sources)
    conflict_set = set(conflict_sources)

    for source_relative_path, final_path in plan_mapping.items():
        final_relative = Path(final_path)
        final_dest_path = dest / final_relative
        source_hash = source_hashes[source_relative_path]

        if source_relative_path in conflict_set:
            original_state = preseeded_state[str(final_relative)]
            current = {
                "sha256": sha256_file(final_dest_path),
                "mtime_ns": final_dest_path.stat().st_mtime_ns,
                "size": final_dest_path.stat().st_size,
            }
            if current != {
                "sha256": original_state["sha256"],
                "mtime_ns": original_state["mtime_ns"],
                "size": original_state["size"],
            }:
                raise AssertionError(f"conflict base file was overwritten: {final_relative}")

            renamed_path = dest / path_with_suffix(final_relative, 1)
            if not renamed_path.exists():
                raise AssertionError(f"missing renamed conflict file: {renamed_path}")
            if sha256_file(renamed_path) != source_hash:
                raise AssertionError(f"renamed conflict file hash mismatch: {renamed_path}")
            continue

        if not final_dest_path.exists():
            raise AssertionError(f"expected final file missing: {final_dest_path}")
        if sha256_file(final_dest_path) != source_hash:
            raise AssertionError(f"final file hash mismatch: {final_dest_path}")

        if source_relative_path in duplicate_set:
            renamed_duplicate = dest / path_with_suffix(final_relative, 1)
            if renamed_duplicate.exists():
                raise AssertionError(f"unexpected renamed duplicate file: {renamed_duplicate}")


def is_sidecar_path(relative_path: str) -> bool:
    return Path(relative_path).suffix.lower().lstrip(".") in SIDECAR_EXTENSIONS


def media_candidate_count(plan_mapping: Dict[str, str]) -> int:
    return sum(1 for source_relative in plan_mapping.keys() if not is_sidecar_path(source_relative))


def assert_relative_path_matches_scheme(relative_path: Path, path_scheme: PathSchemeConfig, scenario_name: str) -> None:
    components = list(relative_path.parts)
    if not components:
        raise AssertionError(f"{scenario_name}: empty final relative path")
    index = 0
    if components[0] == "_unsorted":
        index = 1
    else:
        if len(components) < 4:
            raise AssertionError(f"{scenario_name}: final path has too few components: {relative_path}")

        year_component = components[0]
        month_component = components[1]

        if not (year_component.isdigit() and len(year_component) == 4):
            raise AssertionError(f"{scenario_name}: invalid year component in final path: {relative_path}")

        if path_scheme.chronological_layout == "YYYY/YYYYMM":
            if not (month_component.isdigit() and len(month_component) == 6 and month_component.startswith(year_component)):
                raise AssertionError(
                    f"{scenario_name}: expected YYYY/YYYYMM chronology, got {relative_path}"
                )
        elif path_scheme.chronological_layout == "YYYY/MM":
            if not (month_component.isdigit() and len(month_component) == 2):
                raise AssertionError(f"{scenario_name}: expected YYYY/MM chronology, got {relative_path}")
        else:
            raise AssertionError(f"{scenario_name}: unsupported chronology layout: {path_scheme.chronological_layout}")

        index = 2

    if path_scheme.include_camera_folder:
        if index >= len(components) - 1:
            raise AssertionError(f"{scenario_name}: missing camera component in final path: {relative_path}")
        camera_component = components[index]
        if camera_component in {"Photos", "Videos"}:
            raise AssertionError(f"{scenario_name}: camera folder missing where required: {relative_path}")
        index += 1

    if index >= len(components) - 1:
        raise AssertionError(f"{scenario_name}: missing media folder in final path: {relative_path}")
    media_component = components[index]
    if media_component not in {"Photos", "Videos"}:
        raise AssertionError(f"{scenario_name}: invalid media folder in final path: {relative_path}")
    index += 1

    if media_component == "Photos":
        if path_scheme.split_photo_compression:
            if index >= len(components) - 1:
                raise AssertionError(f"{scenario_name}: missing photo compression folder in final path: {relative_path}")
            compression_component = components[index]
            if compression_component not in PHOTO_COMPRESSION_SEGMENTS:
                raise AssertionError(f"{scenario_name}: invalid photo compression folder in final path: {relative_path}")
            index += 1
        elif index < len(components) - 1 and components[index] in PHOTO_COMPRESSION_SEGMENTS:
            raise AssertionError(f"{scenario_name}: unexpected photo compression folder when split disabled: {relative_path}")
    else:
        if index < len(components) - 1 and components[index] in PHOTO_COMPRESSION_SEGMENTS:
            raise AssertionError(f"{scenario_name}: video path must not include RAW/Non-RAW segment: {relative_path}")

    if index != len(components) - 1:
        raise AssertionError(f"{scenario_name}: unexpected nested structure in final path: {relative_path}")


def assert_new_library_paths_match_scheme(
    before_library: Dict[str, Dict[str, object]],
    after_library: Dict[str, Dict[str, object]],
    expected_committed: int,
    path_scheme: PathSchemeConfig,
    scenario_name: str,
) -> None:
    new_paths = sorted(set(after_library.keys()) - set(before_library.keys()))
    if len(new_paths) != expected_committed:
        raise AssertionError(
            f"{scenario_name}: expected {expected_committed} newly committed library files, found {len(new_paths)}"
        )

    for relative in new_paths:
        assert_relative_path_matches_scheme(Path(relative), path_scheme, scenario_name)


def chronology_components_for_scheme(path_scheme: PathSchemeConfig) -> List[str]:
    year = AUGMENTED_CAPTURE_DATETIME.year
    month = AUGMENTED_CAPTURE_DATETIME.month
    if path_scheme.chronological_layout == "YYYY/YYYYMM":
        return [f"{year:04d}", f"{year:04d}{month:02d}"]
    if path_scheme.chronological_layout == "YYYY/MM":
        return [f"{year:04d}", f"{month:02d}"]
    raise AssertionError(f"unsupported chronology layout: {path_scheme.chronological_layout}")


def expected_augmented_final_paths(path_scheme: PathSchemeConfig) -> Dict[str, Path]:
    dated_unknown_prefix = chronology_components_for_scheme(path_scheme)
    dated_known_prefix = chronology_components_for_scheme(path_scheme)
    unsorted_unknown_prefix = ["_unsorted"]
    if path_scheme.include_camera_folder:
        dated_unknown_prefix = dated_unknown_prefix + ["unknown-camera"]
        dated_known_prefix = dated_known_prefix + [KNOWN_CAMERA_LABEL]
        unsorted_unknown_prefix = unsorted_unknown_prefix + ["unknown-camera"]

    raw_dir = dated_unknown_prefix + ["Photos"]
    non_raw_dir = dated_unknown_prefix + ["Photos"]
    video_dir = dated_unknown_prefix + ["Videos"]
    known_video_dir = dated_known_prefix + ["Videos"]
    unsorted_non_raw_dir = unsorted_unknown_prefix + ["Photos"]
    unsorted_video_dir = unsorted_unknown_prefix + ["Videos"]

    if path_scheme.split_photo_compression:
        raw_dir = raw_dir + ["RAW"]
        non_raw_dir = non_raw_dir + ["Non-RAW"]
        unsorted_non_raw_dir = unsorted_non_raw_dir + ["Non-RAW"]

    return {
        "DCIM/E2E_RAW.CR3": Path(*raw_dir, "E2E_RAW.CR3"),
        "DCIM/E2E_RAW.XMP": Path(*raw_dir, "E2E_RAW.XMP"),
        "DCIM/E2E_STD.JPG": Path(*non_raw_dir, "E2E_STD.JPG"),
        "DCIM/E2E_STD.XMP": Path(*non_raw_dir, "E2E_STD.XMP"),
        "PRIVATE/E2E_VID.MP4": Path(*video_dir, "E2E_VID.MP4"),
        "PRIVATE/E2E_VID.XML": Path(*video_dir, "E2E_VID.XML"),
        "PRIVATE/E2E_KNOWN.MP4": Path(*known_video_dir, "E2E_KNOWN.MP4"),
        "PRIVATE/E2E_KNOWNM01.XML": Path(*known_video_dir, "E2E_KNOWNM01.XML"),
        "DCIM/E2E_UNSORTED.JPG": Path(*unsorted_non_raw_dir, "E2E_UNSORTED.JPG"),
        "PRIVATE/E2E_UNSORTED.MP4": Path(*unsorted_video_dir, "E2E_UNSORTED.MP4"),
        "PRIVATE/E2E_UNSORTED.XML": Path(*unsorted_video_dir, "E2E_UNSORTED.XML"),
    }


def assert_augmented_file_paths(
    scenario_name: str,
    source_dir: Path,
    dest: Path,
    plan_mapping: Dict[str, str],
    source_hashes: Dict[str, str],
    path_scheme: PathSchemeConfig,
) -> None:
    expected_paths = expected_augmented_final_paths(path_scheme)

    for source_relative, expected_relative in expected_paths.items():
        planned_relative = Path(plan_mapping.get(source_relative, ""))
        if planned_relative != expected_relative:
            raise AssertionError(
                f"{scenario_name}: augmented file planned path mismatch for {source_relative}: "
                f"expected {expected_relative}, got {planned_relative}"
            )

        final_dest = dest / expected_relative
        if not final_dest.exists():
            raise AssertionError(f"{scenario_name}: augmented file missing at expected path: {final_dest}")

        expected_hash = source_hashes.get(source_relative)
        if expected_hash is None:
            expected_hash = sha256_file(source_dir / source_relative)
        actual_hash = sha256_file(final_dest)
        if actual_hash != expected_hash:
            raise AssertionError(
                f"{scenario_name}: augmented file hash mismatch at {final_dest}: {actual_hash} != {expected_hash}"
            )


def build_runtime_source(source_dir: Path, scenario_root: Path, augment: bool) -> Path:
    if not augment:
        return source_dir

    runtime_source = scenario_root / "source"
    copy_tree_contents(source_dir, runtime_source)

    for relative, content in AUGMENTED_FILES.items():
        target = runtime_source / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(content)
        os.utime(target, (AUGMENTED_CAPTURE_TIMESTAMP, AUGMENTED_CAPTURE_TIMESTAMP))

    return runtime_source


def execute_scenario(
    binary: Path,
    working_root: Path,
    source: SourceConfig,
    scenario: Scenario,
) -> None:
    scenario_root = working_root / scenario.name
    dest = scenario_root / "dest"
    dest.mkdir(parents=True, exist_ok=True)

    scenario_source_dir = build_runtime_source(source.source_dir, scenario_root, scenario.augment_source)
    outside_file = scenario_root / "outside-sentinel.txt"
    outside_file.write_text("outside sentinel\n", encoding="utf-8")
    sibling_before = path_state(scenario_root)
    source_manifest = file_manifest(scenario_source_dir)
    env_overrides: Dict[str, str] = {}
    if scenario.forced_missing_capture_date_paths:
        env_overrides["ROLLKEEP_TEST_FORCE_MISSING_CAPTURE_DATE_RELATIVE_PATHS"] = ",".join(
            scenario.forced_missing_capture_date_paths
        )

    plan_mapping, source_hashes = plan_files(
        binary=binary,
        source=scenario_source_dir,
        scratch_root=scenario_root / "planning",
        extra_args=scenario.path_scheme.cli_args,
        env_overrides=env_overrides or None,
    )

    preseeded_state = prepare_destination(
        dest=dest,
        fixture_dirs=scenario.fixture_dirs,
        source_dir=scenario_source_dir,
        plan_mapping=plan_mapping,
        duplicate_sources=scenario.duplicate_sources,
        conflict_sources=scenario.conflict_sources,
        seed_all_duplicates=scenario.seed_all_duplicates,
    )

    base_library_state = library_state(dest)
    run_count = 2 if scenario.rerun else 1
    expected_duplicates = len(plan_mapping) if scenario.seed_all_duplicates and not scenario.rerun else len(scenario.duplicate_sources)
    expected_conflicts = len(scenario.conflict_sources)
    expected_committed = len(plan_mapping) - expected_duplicates
    expected_copied_and_verified = len(plan_mapping)

    first_run_renamed_paths = {
        str(path_with_suffix(Path(plan_mapping[source_relative]), 1))
        for source_relative in scenario.conflict_sources
    }
    state_after_first_run: Optional[Dict[str, Dict[str, object]]] = None

    for index in range(run_count):
        summary = run_rollkeep(
            binary,
            scenario_source_dir,
            dest,
            extra_args=scenario.path_scheme.cli_args,
            env_overrides=env_overrides or None,
        )
        receipt_path = Path(summary["receipt"]["path"])
        events = parse_receipt_events(receipt_path)
        receipt_summary = summary_event(events)

        if index == 1:
            expected_duplicates = len(plan_mapping)
            expected_conflicts = 0
            expected_committed = 0
            expected_copied_and_verified = len(plan_mapping)

        counts = summary["counts"]
        if summary["status"] != "completed":
            raise AssertionError(f"{scenario.name} did not complete successfully: {summary}")
        if summary["status_label"] != "VERIFIED":
            raise AssertionError(f"{scenario.name} did not report VERIFIED: {summary['status_label']}")
        if counts["candidates"] != media_candidate_count(plan_mapping):
            raise AssertionError(f"{scenario.name} candidate count mismatch: {counts['candidates']}")
        if counts["duplicate_not_copied"] != expected_duplicates:
            raise AssertionError(f"{scenario.name} duplicate count mismatch: {counts['duplicate_not_copied']} != {expected_duplicates}")
        if counts["conflicts_renamed"] != expected_conflicts:
            raise AssertionError(f"{scenario.name} conflict count mismatch: {counts['conflicts_renamed']} != {expected_conflicts}")
        if counts["committed"] != expected_committed:
            raise AssertionError(f"{scenario.name} committed count mismatch: {counts['committed']} != {expected_committed}")
        if counts["copied"] != expected_copied_and_verified:
            raise AssertionError(f"{scenario.name} copied count mismatch: {counts['copied']} != {expected_copied_and_verified}")
        if counts["verified"] != expected_copied_and_verified:
            raise AssertionError(f"{scenario.name} verified count mismatch: {counts['verified']} != {expected_copied_and_verified}")
        if counts["errors"] != 0:
            raise AssertionError(f"{scenario.name} reported errors: {counts['errors']}")

        classification = summary["idempotency"]["classification"]
        expected_classification = "idempotent_rerun" if expected_committed == 0 and expected_duplicates > 0 else "new_files_committed"
        if classification != expected_classification:
            raise AssertionError(f"{scenario.name} idempotency mismatch: {classification} != {expected_classification}")

        if not receipt_path.exists():
            raise AssertionError(f"{scenario.name} receipt missing: {receipt_path}")
        if Path(summary["staging_session_path"]).exists():
            raise AssertionError(f"{scenario.name} left staging behind on success: {summary['staging_session_path']}")

        assert_path_scheme_events(events, scenario.path_scheme)
        assert_event_presence(
            events,
            expected_copied_and_verified,
            expected_committed,
            expected_duplicates,
            expected_conflicts,
        )
        assert_touched_paths(receipt_summary, dest, scenario_source_dir)

        if index == 0:
            assert_expected_final_files(
                source_dir=scenario_source_dir,
                dest=dest,
                plan_mapping=plan_mapping,
                source_hashes=source_hashes,
                duplicate_sources=list(plan_mapping.keys()) if expected_duplicates == len(plan_mapping) else scenario.duplicate_sources,
                conflict_sources=scenario.conflict_sources,
                preseeded_state=preseeded_state,
            )
            assert_preseeded_files_unchanged(preseeded_state, dest)

            after_library = library_state(dest)
            assert_new_library_paths_match_scheme(
                before_library=base_library_state,
                after_library=after_library,
                expected_committed=expected_committed,
                path_scheme=scenario.path_scheme,
                scenario_name=scenario.name,
            )

            if scenario.augment_source:
                assert_augmented_file_paths(
                    scenario_name=scenario.name,
                    source_dir=scenario_source_dir,
                    dest=dest,
                    plan_mapping=plan_mapping,
                    source_hashes=source_hashes,
                    path_scheme=scenario.path_scheme,
                )

            state_after_first_run = after_library
        else:
            if library_state(dest) != state_after_first_run:
                raise AssertionError(f"{scenario.name} rerun changed destination state")
            for renamed_relative in first_run_renamed_paths:
                if not (dest / renamed_relative).exists():
                    raise AssertionError(f"{scenario.name} rerun lost prior renamed file: {renamed_relative}")

        assert_source_unchanged(source_manifest, scenario_source_dir)

    assert_no_sibling_writes(sibling_before, scenario_root, dest)


def build_default_scenarios(sources: Dict[str, SourceConfig], fixture_data: Dict[str, Dict[str, Dict[str, List[str]]]]) -> List[Scenario]:
    return [
        Scenario(
            name="sd1-baseline-existing-tree",
            source_key="sd1",
            fixture_dirs=[sources["sd1"].baseline_fixture],
            duplicate_sources=[],
            conflict_sources=[],
            path_scheme=DEFAULT_PATH_SCHEME,
        ),
        Scenario(
            name="sd1-duplicate-preseeded",
            source_key="sd1",
            fixture_dirs=[sources["sd1"].duplicate_fixture],
            duplicate_sources=fixture_data["sd1"]["duplicate"]["duplicate_source_paths"],
            conflict_sources=[],
            path_scheme=DEFAULT_PATH_SCHEME,
        ),
        Scenario(
            name="sd1-conflict-preseeded",
            source_key="sd1",
            fixture_dirs=[sources["sd1"].conflict_fixture],
            duplicate_sources=[],
            conflict_sources=fixture_data["sd1"]["conflict"]["conflict_source_paths"],
            path_scheme=DEFAULT_PATH_SCHEME,
        ),
        Scenario(
            name="sd1-mixed-existing-tree",
            source_key="sd1",
            fixture_dirs=[sources["sd1"].baseline_fixture, sources["sd1"].duplicate_fixture, sources["sd1"].conflict_fixture],
            duplicate_sources=fixture_data["sd1"]["duplicate"]["duplicate_source_paths"],
            conflict_sources=fixture_data["sd1"]["conflict"]["conflict_source_paths"],
            path_scheme=DEFAULT_PATH_SCHEME,
        ),
        Scenario(
            name="sd1-full-duplicate-existing-tree",
            source_key="sd1",
            fixture_dirs=[sources["sd1"].baseline_fixture],
            duplicate_sources=[],
            conflict_sources=[],
            path_scheme=DEFAULT_PATH_SCHEME,
            seed_all_duplicates=True,
        ),
        Scenario(
            name="sd1-mixed-rerun-existing-tree",
            source_key="sd1",
            fixture_dirs=[sources["sd1"].baseline_fixture, sources["sd1"].duplicate_fixture, sources["sd1"].conflict_fixture],
            duplicate_sources=fixture_data["sd1"]["duplicate"]["duplicate_source_paths"],
            conflict_sources=fixture_data["sd1"]["conflict"]["conflict_source_paths"],
            path_scheme=DEFAULT_PATH_SCHEME,
            rerun=True,
        ),
        Scenario(
            name="sd2-baseline-existing-tree",
            source_key="sd2",
            fixture_dirs=[sources["sd2"].baseline_fixture],
            duplicate_sources=[],
            conflict_sources=[],
            path_scheme=DEFAULT_PATH_SCHEME,
        ),
        Scenario(
            name="sd2-duplicate-preseeded",
            source_key="sd2",
            fixture_dirs=[sources["sd2"].duplicate_fixture],
            duplicate_sources=fixture_data["sd2"]["duplicate"]["duplicate_source_paths"],
            conflict_sources=[],
            path_scheme=DEFAULT_PATH_SCHEME,
        ),
        Scenario(
            name="sd2-conflict-preseeded",
            source_key="sd2",
            fixture_dirs=[sources["sd2"].conflict_fixture],
            duplicate_sources=[],
            conflict_sources=fixture_data["sd2"]["conflict"]["conflict_source_paths"],
            path_scheme=DEFAULT_PATH_SCHEME,
        ),
        Scenario(
            name="sd2-mixed-existing-tree",
            source_key="sd2",
            fixture_dirs=[sources["sd2"].baseline_fixture, sources["sd2"].duplicate_fixture, sources["sd2"].conflict_fixture],
            duplicate_sources=fixture_data["sd2"]["duplicate"]["duplicate_source_paths"],
            conflict_sources=fixture_data["sd2"]["conflict"]["conflict_source_paths"],
            path_scheme=DEFAULT_PATH_SCHEME,
        ),
        Scenario(
            name="sd2-full-duplicate-existing-tree",
            source_key="sd2",
            fixture_dirs=[sources["sd2"].baseline_fixture],
            duplicate_sources=[],
            conflict_sources=[],
            path_scheme=DEFAULT_PATH_SCHEME,
            seed_all_duplicates=True,
        ),
        Scenario(
            name="sd2-mixed-rerun-existing-tree",
            source_key="sd2",
            fixture_dirs=[sources["sd2"].baseline_fixture, sources["sd2"].duplicate_fixture, sources["sd2"].conflict_fixture],
            duplicate_sources=fixture_data["sd2"]["duplicate"]["duplicate_source_paths"],
            conflict_sources=fixture_data["sd2"]["conflict"]["conflict_source_paths"],
            path_scheme=DEFAULT_PATH_SCHEME,
            rerun=True,
        ),
    ]


def build_path_scheme_matrix_scenarios(
    sources: Dict[str, SourceConfig],
    fixture_data: Dict[str, Dict[str, Dict[str, List[str]]]],
) -> List[Scenario]:
    scenarios: List[Scenario] = []
    for source_key in ["sd1", "sd2"]:
        for path_scheme in PATH_SCHEMES:
            scenarios.append(
                Scenario(
                    name=f"{source_key}-mixed-existing-tree-{path_scheme.slug}",
                    source_key=source_key,
                    fixture_dirs=[
                        sources[source_key].baseline_fixture,
                        sources[source_key].duplicate_fixture,
                        sources[source_key].conflict_fixture,
                    ],
                    duplicate_sources=fixture_data[source_key]["duplicate"]["duplicate_source_paths"],
                    conflict_sources=fixture_data[source_key]["conflict"]["conflict_source_paths"],
                    path_scheme=path_scheme,
                    rerun=True,
                    augment_source=True,
                    forced_missing_capture_date_paths=FORCED_MISSING_CAPTURE_DATE_PATHS,
                )
            )
    return scenarios


def main() -> int:
    parser = argparse.ArgumentParser(description="Run existing-HDD CLI e2e tests.")
    parser.add_argument("--binary", required=True, help="Path to the rollkeep binary.")
    parser.add_argument("--repo-root", required=True, help="Repository root.")
    args = parser.parse_args()

    repo_root = Path(args.repo_root).resolve()
    binary = Path(args.binary).resolve()
    testing_root = repo_root / "Tests" / "TestingDirs"

    sources = {
        "sd1": SourceConfig(
            label="SD_CARD1",
            source_dir=testing_root / "SD_CARD1",
            baseline_fixture=testing_root / "E2E_EXISTING_HDD_BASELINE_SD1",
            duplicate_fixture=testing_root / "E2E_EXISTING_HDD_DUPLICATE_PRESEEDED_SD1",
            conflict_fixture=testing_root / "E2E_EXISTING_HDD_CONFLICT_PRESEEDED_SD1",
        ),
        "sd2": SourceConfig(
            label="SD_CARD2",
            source_dir=testing_root / "SD_CARD2",
            baseline_fixture=testing_root / "E2E_EXISTING_HDD_BASELINE_SD2",
            duplicate_fixture=testing_root / "E2E_EXISTING_HDD_DUPLICATE_PRESEEDED_SD2",
            conflict_fixture=testing_root / "E2E_EXISTING_HDD_CONFLICT_PRESEEDED_SD2",
        ),
    }

    fixture_data = {
        key: {
            "baseline": load_fixture(config.baseline_fixture),
            "duplicate": load_fixture(config.duplicate_fixture),
            "conflict": load_fixture(config.conflict_fixture),
        }
        for key, config in sources.items()
    }

    default_scenarios = build_default_scenarios(sources, fixture_data)
    matrix_scenarios = build_path_scheme_matrix_scenarios(sources, fixture_data)
    scenarios = default_scenarios + matrix_scenarios

    with tempfile.TemporaryDirectory(prefix="rollkeep-existing-hdd-e2e-") as execution_root:
        for scenario in scenarios:
            source = sources[scenario.source_key]
            execute_scenario(
                binary=binary,
                working_root=Path(execution_root),
                source=source,
                scenario=scenario,
            )
            print(f"[pass] {scenario.name}")

    print("Existing-HDD e2e checks passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
