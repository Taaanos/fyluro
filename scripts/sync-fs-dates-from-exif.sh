#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  scripts/sync-fs-dates-from-exif.sh <root-dir> [--apply]

Behavior:
  - Default mode is dry-run (prints planned changes only).
  - Reads capture timestamp from metadata in this priority:
      DateTimeOriginal -> CreateDate -> MediaCreateDate -> TrackCreateDate -> CreationDate
  - Sets filesystem Date Modified to that timestamp.
  - On macOS, also sets Date Created when `SetFile` is available.

Requirements:
  - exiftool
  - macOS optional: SetFile (Xcode Command Line Tools) for Date Created
EOF
}

if [[ $# -lt 1 || $# -gt 2 ]]; then
  usage
  exit 1
fi

ROOT="${1:-}"
MODE="${2:-}"
APPLY=false

if [[ -n "$MODE" && "$MODE" != "--apply" ]]; then
  echo "Error: unknown option '$MODE'" >&2
  usage
  exit 1
fi

if [[ "$MODE" == "--apply" ]]; then
  APPLY=true
fi

if [[ ! -d "$ROOT" ]]; then
  echo "Error: directory not found: $ROOT" >&2
  exit 1
fi

if ! command -v exiftool >/dev/null 2>&1; then
  echo "Error: exiftool is required but not installed." >&2
  exit 1
fi

HAS_SETFILE=false
if command -v SetFile >/dev/null 2>&1; then
  HAS_SETFILE=true
fi

extract_touch_ts() {
  local file="$1"
  exiftool -api QuickTimeUTC=1 -s3 -d '%Y%m%d%H%M.%S' \
    -DateTimeOriginal -CreateDate -MediaCreateDate -TrackCreateDate -CreationDate \
    "$file" | awk 'NF { print; exit }'
}

to_setfile_ts() {
  local touch_ts="$1"
  date -j -f "%Y%m%d%H%M.%S" "$touch_ts" "+%m/%d/%Y %H:%M:%S"
}

processed=0
updated=0
skipped=0
failed=0

while IFS= read -r -d '' file; do
  processed=$((processed + 1))
  ts="$(extract_touch_ts "$file" || true)"

  if [[ -z "$ts" ]]; then
    skipped=$((skipped + 1))
    echo "SKIP  no metadata date: $file"
    continue
  fi

  if [[ "$APPLY" == false ]]; then
    echo "PLAN  touch -t $ts \"$file\""
    if [[ "$HAS_SETFILE" == true ]]; then
      setfile_ts="$(to_setfile_ts "$ts")"
      echo "PLAN  SetFile -d \"$setfile_ts\" \"$file\""
    fi
    updated=$((updated + 1))
    continue
  fi

  if touch -t "$ts" "$file"; then
    if [[ "$HAS_SETFILE" == true ]]; then
      setfile_ts="$(to_setfile_ts "$ts")"
      if ! SetFile -d "$setfile_ts" "$file"; then
        echo "WARN  failed to set Date Created: $file"
      fi
    fi
    echo "OK    synced dates: $file"
    updated=$((updated + 1))
  else
    echo "FAIL  failed touch: $file"
    failed=$((failed + 1))
  fi
done < <(
  find "$ROOT" -type f \( \
    -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.heic' -o -iname '*.png' -o \
    -iname '*.dng' -o -iname '*.arw' -o -iname '*.cr2' -o -iname '*.cr3' -o \
    -iname '*.nef' -o -iname '*.raf' -o -iname '*.tif' -o -iname '*.tiff' -o \
    -iname '*.mp4' -o -iname '*.mov' -o -iname '*.m4v' -o -iname '*.avi' -o \
    -iname '*.mts' -o -iname '*.mxf' \
  \) -print0
)

echo
echo "Summary:"
echo "  processed: $processed"
echo "  matched/updated: $updated"
echo "  skipped(no metadata date): $skipped"
echo "  failed: $failed"
echo "  mode: $([[ "$APPLY" == true ]] && echo apply || echo dry-run)"

if [[ "$HAS_SETFILE" == false ]]; then
  echo "  note: SetFile not found; Date Created was not updated."
fi
