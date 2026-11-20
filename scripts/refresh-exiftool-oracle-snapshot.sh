#!/bin/zsh

set -euo pipefail

# Regenerates the committed exiftool oracle snapshot consumed by
# ExifToolOracleParityTests. The snapshot records what exiftool extracts as
# camera Make/Model/serial for a camera-relevant subset of its own bundled
# test corpus (t/images), so the corpus parity test can run without perl (using t/images from
# FYLURO_EXIFTOOL_CHECKOUT).
#
# Requires a local exiftool checkout (NOT vendored into this repo -- it is
# Artistic/GPL licensed and used strictly as a dev-time oracle). Set
# FYLURO_EXIFTOOL_CHECKOUT to its path.
#
# Rerun this after bumping the exiftool checkout to a new release, then
# review the diff: changed entries are exactly where upstream learned (or
# changed) camera identification -- patch the Swift tables to match. See the
# sync procedure in docs/guides/exiftool-sync.md.

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHECKOUT="${FYLURO_EXIFTOOL_CHECKOUT:-}"
OUT="$REPO_ROOT/Tests/fyluroTests/Fixtures/exiftool-oracle-snapshot.json"

if [[ -z "$CHECKOUT" || ! -f "$CHECKOUT/exiftool" ]]; then
    echo "error: exiftool checkout not found; set FYLURO_EXIFTOOL_CHECKOUT" >&2
    exit 1
fi
if ! command -v perl >/dev/null; then
    echo "error: perl not found" >&2
    exit 1
fi
if ! command -v python3 >/dev/null; then
    echo "error: python3 not found" >&2
    exit 1
fi

# Camera-relevant subset of t/images: vendor JPEGs, RAW formats, and the
# video/container samples the milestones target. Keep this list stable and
# explicit so snapshot diffs stay reviewable.
typeset -a files=(
    # Vendor JPEGs (EXIF path)
    t/images/Apple.jpg
    t/images/Canon.jpg
    t/images/Canon1DmkIII.jpg
    t/images/Casio.jpg
    t/images/Casio2.jpg
    t/images/FujiFilm.jpg
    t/images/GE.jpg
    t/images/GoPro.jpg
    t/images/JVC.jpg
    t/images/JVC2.jpg
    t/images/Kodak.jpg
    t/images/Minolta.jpg
    t/images/Motorola.jpg
    t/images/Nikon.jpg
    t/images/NikonD2Hs.jpg
    t/images/NikonD70.jpg
    t/images/Olympus.jpg
    t/images/Olympus2.jpg
    t/images/OlympusE1.jpg
    t/images/Panasonic.jpg
    t/images/Pentax.jpg
    t/images/Ricoh.jpg
    t/images/Ricoh2.jpg
    t/images/Sanyo.jpg
    t/images/Sigma.jpg
    t/images/Sony.jpg
    # TIFF / RAW formats
    t/images/ExifTool.tif
    t/images/CanonRaw.cr2
    t/images/CanonRaw.cr3
    t/images/CanonRaw.crw
    t/images/Nikon.nef
    t/images/FujiFilm.raf
    t/images/Panasonic.rw2
    t/images/DNG.dng
    t/images/Sigma.x3f
    t/images/SigmaDP2.x3f
    t/images/PhaseOne.iiq
    t/images/Minolta.mrw
    t/images/KyoceraRaw.raw
    # Photo container
    t/images/QuickTime.heic
    # Video / containers (M1/M3/M4 targets)
    t/images/QuickTime.mov
    t/images/M2TS.mts
    t/images/Pentax.avi
    t/images/MXF.mxf
)

mkdir -p "$(dirname "$OUT")"

version="$(perl "$CHECKOUT/exiftool" -ver)"
tmpjson="$(mktemp -t fyluro-exiftool-oracle)"
trap 'rm -f "$tmpjson"' EXIT

(
    cd "$CHECKOUT"
    # Camera identity is not always under Make/Model: Sony XAVC XML uses
    # DeviceManufacturer/DeviceModelName, phones use AndroidManufacturer/
    # AndroidModel. Request the aliases and coalesce below so the snapshot
    # reflects everything exiftool knows about the device.
    perl exiftool -j -q \
        -Make -Model \
        -DeviceManufacturer -DeviceModelName \
        -AndroidManufacturer -AndroidModel \
        -SerialNumber -BodySerialNumber -CameraSerialNumber -InternalSerialNumber -DeviceSerialNo \
        -UniqueCameraModel \
        "${files[@]}" > "$tmpjson"
)

python3 - "$version" "$tmpjson" "$OUT" <<'PY'
import json
import sys

version, src, out = sys.argv[1], sys.argv[2], sys.argv[3]
with open(src) as f:
    rows = json.load(f)

MAKE_PRIORITY = ("Make", "DeviceManufacturer", "AndroidManufacturer")
MODEL_PRIORITY = ("Model", "DeviceModelName", "AndroidModel")
SERIAL_PRIORITY = (
    "BodySerialNumber",
    "SerialNumber",
    "CameraSerialNumber",
    "InternalSerialNumber",
    "DeviceSerialNo",
)


def pick(row, keys):
    value = next((row[key] for key in keys if row.get(key) not in (None, "")), None)
    return None if value is None else str(value)


entries = {}
for row in rows:
    name = row.get("SourceFile", "").split("/")[-1]
    entries[name] = {
        "make": pick(row, MAKE_PRIORITY),
        "model": pick(row, MODEL_PRIORITY),
        "serial": pick(row, SERIAL_PRIORITY),
        "uniqueCameraModel": row.get("UniqueCameraModel"),
    }

snapshot = {"exiftoolVersion": version, "entries": entries}
with open(out, "w") as f:
    json.dump(snapshot, f, indent=2, sort_keys=True, ensure_ascii=False)
    f.write("\n")

print(f"wrote {out} ({len(entries)} entries, exiftool {version})")
PY
