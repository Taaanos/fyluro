#!/usr/bin/env python3
"""Build the gitignored E2E source-card fixtures from the local real-media set.

Maps files from a local directory of real camera media (default:
Tests/TestingDirs, override with
ROLLKEEP_FIXTURE_SOURCE_DIR) into two simulated card trees:

  Tests/TestingDirs/SD_CARD1  -- Apple phone card (flat DCIM/)
  Tests/TestingDirs/SD_CARD2  -- mixed multi-camera card (vendor DCIM
                                 subfolders + Sony PRIVATE/M4ROOT/CLIP)

Writes Tests/TestingDirs/fixture-manifest.json (path, size, sha256) so
fixture drift is detectable. `--check` verifies the built cards against the
manifest without rebuilding.

The mapping below is the source of truth for card contents. The paths marked
"pinned" are referenced by name in the E2E harnesses (FAST_SOURCE_SUBSET_PATHS
in scripts/existing-hdd-e2e.py, the E2E_EXISTING_HDD_* fixture.json files,
matrixSlimRelativePaths in Tests/rollkeepLauncherTests/LauncherAppE2ETests.swift,
and scripts/e2e-verify-failure-test.sh) -- keep them in sync.
"""

import argparse
import hashlib
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
TESTING_DIRS = REPO_ROOT / "Tests" / "TestingDirs"
MANIFEST_PATH = TESTING_DIRS / "fixture-manifest.json"
DEFAULT_SOURCE_DIR = REPO_ROOT / "Tests" / "TestingDirs"

PHOTO_EXTENSIONS = {"jpg", "jpeg", "png", "heic", "heif", "dng", "cr2", "cr3", "arw", "gpr"}
VIDEO_EXTENSIONS = {"mov", "mp4", "m4v", "insv"}
AUDIO_EXTENSIONS = {"wav", "mp3", "m4a", "aac", "caf", "aif", "aiff"}

# card name -> { source path relative to the fixture source dir -> card-relative path }
CARD_MAPPINGS = {
    "SD_CARD1": {
        "iphone 12 mini/IMG_2940.HEIC": "DCIM/IMG_2940.HEIC",
        # pinned: matrix slim subset + duplicate source + verify-failure fixture
        "iphone 13 pro/IMG_8236.HEIC": "DCIM/IMG_8236.HEIC",
        "iphone 13 pro/IMG_8248.DNG": "DCIM/IMG_8248.DNG",
        "iphone 13 pro/IMG_8249.MOV": "DCIM/IMG_8249.MOV",
        "iphone 15 pro/IMG_0083.DNG": "DCIM/IMG_0083.DNG",
        "iphone 15 pro/IMG_0168.MOV": "DCIM/IMG_0168.MOV",
        # pinned: matrix slim subset + conflict source
        "iphone 15 pro/IMG_0187.HEIC": "DCIM/IMG_0187.HEIC",
        "iphone 16/IMG_0245.MOV": "DCIM/IMG_0245.MOV",
        # screenshot: no Make/Model -> unknown-camera label coverage
        "screenshots/IMG_0076.PNG": "DCIM/IMG_0076.PNG",
        # Blackmagic-app iPhone clip: nonstandard naming coverage
        "iphone 15 pro/A001_06041206_C097.mov": "DCIM/A001_06041206_C097.mov",
        # standalone audio recording, no paired video: standalone-Audio-candidate coverage
        "iphone recordings/iphone recording.m4a": "DCIM/iphone recording.m4a",
    },
    "SD_CARD2": {
        # Sony stills
        # pinned: duplicate source
        "rx100/DSC01930.JPG": "DCIM/100MSDCF/DSC01930.JPG",
        "rx100/DSC02701.ARW": "DCIM/100MSDCF/DSC02701.ARW",
        # same-basename RAW+JPG pair
        "rx100 mk6/DSC00421.JPG": "DCIM/100MSDCF/DSC00421.JPG",
        "rx100 mk6/DSC00421.ARW": "DCIM/100MSDCF/DSC00421.ARW",
        "a7c2/DSC02577.ARW": "DCIM/100MSDCF/DSC02577.ARW",
        "a6000/DSC08259.ARW": "DCIM/100MSDCF/DSC08259.ARW",
        "a380/DSC09387.ARW": "DCIM/100MSDCF/DSC09387.ARW",
        # Canon
        "5DM2/IMG_1765.CR2": "DCIM/100CANON/IMG_1765.CR2",
        # GoPro (GPR is a supported RAW photo format, bucketed like other RAW formats)
        "hero 10/G0010306.JPG": "DCIM/100GOPRO/G0010306.JPG",
        "hero 10/G0010306.GPR": "DCIM/100GOPRO/G0010306.GPR",
        "hero 10/G0010044.JPG": "DCIM/100GOPRO/G0010044.JPG",
        "hero 10/G0010044.GPR": "DCIM/100GOPRO/G0010044.GPR",
        "hero 10/GX010645.MP4": "DCIM/100GOPRO/GX010645.MP4",
        "hero 10/GX020024.MP4": "DCIM/100GOPRO/GX020024.MP4",
        # DJI action cams
        "action-4/DJI_20240218122338_0019_D.JPG": "DCIM/100MEDIA/DJI_20240218122338_0019_D.JPG",
        "action-4/DJI_20240218140744_0024_D.DNG": "DCIM/100MEDIA/DJI_20240218140744_0024_D.DNG",
        "action-4/DJI_20240204134712_0013_D.MP4": "DCIM/100MEDIA/DJI_20240204134712_0013_D.MP4",
        "action-6/DJI_20260613062714_0010_D.MP4": "DCIM/100MEDIA/DJI_20260613062714_0010_D.MP4",
        # DJI drone/pocket (SRT sidecar pair; WAV is video-companion-audio sidecar coverage)
        "mini-4-pro/DJI_20260523115129_0558_D.DNG": "DCIM/DJI_001/DJI_20260523115129_0558_D.DNG",
        "mini-4-pro/DJI_20260523115257_0565_D.MP4": "DCIM/DJI_001/DJI_20260523115257_0565_D.MP4",
        "mini-4-pro/DJI_20260523115257_0565_D.SRT": "DCIM/DJI_001/DJI_20260523115257_0565_D.SRT",
        "pocket-3/DJI_20240126194607_0117_D.JPG": "DCIM/DJI_001/DJI_20240126194607_0117_D.JPG",
        "pocket-3/DJI_20240126194607_0117_D.DNG": "DCIM/DJI_001/DJI_20240126194607_0117_D.DNG",
        "pocket-3/DJI_20240126093104_0012_D.MP4": "DCIM/DJI_001/DJI_20240126093104_0012_D.MP4",
        "pocket-3/DJI_20240126093104_0012_D.WAV": "DCIM/DJI_001/DJI_20240126093104_0012_D.WAV",
        # Samsung phone
        "samsung galaxy a54 /20240809_160800.jpg": "DCIM/CAMERA/20240809_160800.jpg",
        "samsung galaxy a54 /20240809_164400.mp4": "DCIM/CAMERA/20240809_164400.mp4",
        # Lightroom export (re-exported metadata coverage)
        "Lightroom exports/DJI_20240908175300_0011_D.JPG": "DCIM/EXPORT/DJI_20240908175300_0011_D.JPG",
        # Insta360
        "insta360/VID_20231023_055225_00_645.insv": "DCIM/Camera01/VID_20231023_055225_00_645.insv",
        # Sony video clips + real NonRealTimeMeta XML sidecar
        # pinned: conflict source
        "a7c2/20250824_C2864.MP4": "PRIVATE/M4ROOT/CLIP/20250824_C2864.MP4",
        "a7c2/20260618_C5262.MP4": "PRIVATE/M4ROOT/CLIP/20260618_C5262.MP4",
        "a7c2/20260618_C5262M01.XML": "PRIVATE/M4ROOT/CLIP/20260618_C5262M01.XML",
    },
}


def sha256_of(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def resolve_source_dir() -> Path:
    override = os.environ.get("ROLLKEEP_FIXTURE_SOURCE_DIR")
    return Path(override).expanduser() if override else DEFAULT_SOURCE_DIR


def validate_metadata(source_dir: Path) -> int:
    """Best-effort check that media files carry real capture metadata.

    Uses exiftool when available; photos need DateTimeOriginal and videos a
    CreateDate, matching what the scanner extracts via ImageIO/AVFoundation.
    Standalone-audio-capable formats (m4a/mp3/aac/...) also need a CreateDate;
    `.wav` is exempted since it's either a DJI-style video-companion sidecar
    (no capture-date metadata of its own -- inherits its video's) or a
    standalone recording that's expected to fall back to filesystem mtime.
    Returns the number of files that failed validation (warnings only).
    """
    exiftool = shutil.which("exiftool")
    if exiftool is None:
        print("note: exiftool not found; skipping capture-metadata validation")
        return 0
    failures = 0
    for mapping in CARD_MAPPINGS.values():
        for source_relative in mapping:
            source_path = source_dir / source_relative
            ext = source_path.suffix.lower().lstrip(".")
            if ext in PHOTO_EXTENSIONS:
                tag = "DateTimeOriginal"
            elif ext in VIDEO_EXTENSIONS:
                tag = "CreateDate"
            elif ext in AUDIO_EXTENSIONS and ext != "wav":
                tag = "CreateDate"
            else:
                continue
            result = subprocess.run(
                [exiftool, "-s3", f"-{tag}", str(source_path)],
                capture_output=True,
                text=True,
                check=False,
            )
            if not result.stdout.strip():
                print(f"warning: {source_relative}: missing {tag}")
                failures += 1
    return failures


def build(source_dir: Path, force: bool) -> int:
    missing = [
        source_relative
        for mapping in CARD_MAPPINGS.values()
        for source_relative in mapping
        if not (source_dir / source_relative).is_file()
    ]
    if missing:
        print(f"error: fixture source dir {source_dir} is missing {len(missing)} file(s):", file=sys.stderr)
        for source_relative in missing:
            print(f"  {source_relative}", file=sys.stderr)
        return 1

    for card_name in CARD_MAPPINGS:
        card_root = TESTING_DIRS / card_name
        if card_root.exists():
            if not force and MANIFEST_PATH.is_file():
                print(f"{card_name} already exists; use --check to verify or --force to rebuild")
                return 1
            shutil.rmtree(card_root)

    validate_metadata(source_dir)

    manifest = {}
    for card_name, mapping in CARD_MAPPINGS.items():
        card_root = TESTING_DIRS / card_name
        for source_relative, card_relative in mapping.items():
            source_path = source_dir / source_relative
            dest_path = card_root / card_relative
            dest_path.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source_path, dest_path)
            manifest[f"{card_name}/{card_relative}"] = {
                "size": dest_path.stat().st_size,
                "sha256": sha256_of(dest_path),
            }
        file_count = len(mapping)
        total_bytes = sum(
            manifest[f"{card_name}/{card_relative}"]["size"] for card_relative in mapping.values()
        )
        print(f"built {card_name}: {file_count} files, {total_bytes / 1_000_000:.0f} MB")

    MANIFEST_PATH.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    print(f"wrote {MANIFEST_PATH.relative_to(REPO_ROOT)} ({len(manifest)} entries)")
    return 0


def check() -> int:
    if not MANIFEST_PATH.is_file():
        print(f"error: missing manifest {MANIFEST_PATH}; run the build first", file=sys.stderr)
        return 1
    manifest = json.loads(MANIFEST_PATH.read_text())
    problems = []
    for manifest_relative, expected in manifest.items():
        path = TESTING_DIRS / manifest_relative
        if not path.is_file():
            problems.append(f"missing: {manifest_relative}")
        elif path.stat().st_size != expected["size"]:
            problems.append(f"size mismatch: {manifest_relative}")
        elif sha256_of(path) != expected["sha256"]:
            problems.append(f"hash mismatch: {manifest_relative}")
    for card_name in CARD_MAPPINGS:
        card_root = TESTING_DIRS / card_name
        if not card_root.is_dir():
            continue
        for path in card_root.rglob("*"):
            if path.is_file() and path.name != ".DS_Store":
                manifest_relative = str(path.relative_to(TESTING_DIRS))
                if manifest_relative not in manifest:
                    problems.append(f"unexpected file: {manifest_relative}")
    if problems:
        print("fixture check failed:", file=sys.stderr)
        for problem in problems:
            print(f"  {problem}", file=sys.stderr)
        return 1
    print(f"fixture check passed ({len(manifest)} files)")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--check", action="store_true", help="verify built cards against the manifest")
    parser.add_argument("--force", action="store_true", help="rebuild even if cards already exist")
    args = parser.parse_args()
    if args.check:
        return check()
    return build(resolve_source_dir(), force=args.force)


if __name__ == "__main__":
    sys.exit(main())
