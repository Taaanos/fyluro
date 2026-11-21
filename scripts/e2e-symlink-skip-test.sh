#!/bin/zsh

set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/release-common.sh"

function usage() {
    cat <<'EOF'
Run deterministic symlink skip-and-warn E2E check (RT-P1-07).

Usage:
  scripts/e2e-symlink-skip-test.sh

Verifies that symbolic links in the source are skipped (not imported) and
reported as warnings, that their out-of-bound targets are never followed
into the library, that a single stray symlink does not abort the import,
and that the source card is left unchanged.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
fi

release_require_command swift
release_require_command jq
release_enable_swift_local_caches

binary="$RELEASE_REPO_ROOT/.build/debug/fyluro"
release_ensure_debug_fyluro_binary "symlink skip E2E"

fixture_card="$RELEASE_REPO_ROOT/Tests/TestingDirs/SD_CARD1"
[[ -d "$fixture_card" ]] || release_die "missing source fixture: $fixture_card (run scripts/build-e2e-fixtures.py)"

temp_root="$(mktemp -d "${TMPDIR:-/tmp}/fyluro-e2e-symlink.XXXXXX")"
source_path="$temp_root/source"
external_root="$temp_root/external"
dest_path="$temp_root/dest"

function cleanup() {
    rm -rf "$temp_root"
}
trap cleanup EXIT

mkdir -p "$source_path" "$external_root/outside-dir" "$dest_path"

cp -R "$fixture_card"/. "$source_path"

print -n "fyluro-e2e-symlink-target-photo" > "$external_root/secret.JPG"
print -n "fyluro-e2e-symlink-target-in-dir" > "$external_root/outside-dir/hidden.JPG"

ln -s "$external_root/secret.JPG" "$source_path/DCIM/escape.JPG"
ln -s "$external_root/outside-dir" "$source_path/DCIM/linkdir"

# Real media files only (find -type f does not follow or count symlinks).
real_media_count="$(find "$source_path" -type f ! -name '.DS_Store' | wc -l | tr -d ' ')"
[[ "$real_media_count" -gt 0 ]] || release_die "expected at least one real media file in the cloned card"

release_note "Running ingest with two boundary-escaping symlinks planted in the source..."
set +e
output="$("$binary" --source "$source_path" --dest "$dest_path" --json)"
command_exit=$?
set -e

[[ "$command_exit" == "0" ]] || release_die "a stray symlink must not abort import (exit was $command_exit)"

final_json="$(print -r -- "$output" | jq -s '.[-1]')"

[[ "$(print -r -- "$final_json" | jq -r '.status_label')" == "VERIFIED" ]] || release_die "expected status_label=VERIFIED"
[[ "$(print -r -- "$final_json" | jq -r '.counts.errors')" == "0" ]] || release_die "expected errors=0"

committed="$(print -r -- "$final_json" | jq -r '.counts.committed')"
candidates="$(print -r -- "$final_json" | jq -r '.counts.candidates')"
[[ "$candidates" == "$real_media_count" ]] || release_die "symlinks must not be counted as candidates (candidates=$candidates, real=$real_media_count)"
[[ "$committed" == "$real_media_count" ]] || release_die "all real media must commit; symlinks add nothing (committed=$committed, real=$real_media_count)"

if find "$dest_path" \( -name 'secret.JPG' -o -name 'hidden.JPG' -o -name 'escape.JPG' \) | grep -q .; then
    release_die "symlink target or link name leaked into the destination library"
fi

# The source card is left unchanged: both symlinks remain, targets not copied in.
[[ -L "$source_path/DCIM/escape.JPG" ]] || release_die "source symlink escape.JPG was mutated"
[[ -L "$source_path/DCIM/linkdir" ]] || release_die "source symlink linkdir was mutated"

receipt_path="$(print -r -- "$final_json" | jq -r '.receipt.path // empty')"
[[ -n "$receipt_path" && -f "$receipt_path" ]] || release_die "missing receipt path in final summary"

symlink_warning_count="$(grep -c '"category":"symbolic_link_skipped"' "$receipt_path" || true)"
[[ "$symlink_warning_count" -ge 2 ]] || release_die "expected >=2 symbolic_link_skipped SCAN_WARNING events, got $symlink_warning_count"
grep -q '"event_type":"SCAN_WARNING"' "$receipt_path" || release_die "receipt missing SCAN_WARNING event"

release_note "Deterministic symlink skip-and-warn E2E check passed."
