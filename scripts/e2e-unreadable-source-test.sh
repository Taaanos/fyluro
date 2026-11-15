#!/bin/zsh

set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/release-common.sh"

function usage() {
    cat <<'EOF'
Run deterministic unreadable-source-file E2E check (RT-P1-02).

Usage:
  scripts/e2e-unreadable-source-test.sh

Verifies that a single unreadable media file on the source card is recorded
as an explicit scan ERROR, that every other readable file on the card still
ingests deterministically, and that the run still completes VERIFIED with an
accurate error count rather than aborting or silently omitting the file.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
fi

release_require_command swift
release_require_command jq
release_enable_swift_local_caches

binary="$RELEASE_REPO_ROOT/.build/debug/rollkeep"
release_ensure_debug_rollkeep_binary "unreadable-source E2E"

fixture_card="$RELEASE_REPO_ROOT/Tests/TestingDirs/SD_CARD1"
[[ -d "$fixture_card" ]] || release_die "missing source fixture: $fixture_card (run scripts/build-e2e-fixtures.py)"

temp_root="$(mktemp -d "${TMPDIR:-/tmp}/rollkeep-e2e-unreadable.XXXXXX")"
source_path="$temp_root/source"
dest_path="$temp_root/dest"

function cleanup() {
    # chmod the planted file back so rm -rf can remove it under any umask.
    chmod u+rw "$source_path/DCIM/IMG_0083.DNG" 2>/dev/null || true
    rm -rf "$temp_root"
}
trap cleanup EXIT

mkdir -p "$source_path" "$dest_path"

# Clone the real card, then make one real media file unreadable.
cp -R "$fixture_card"/. "$source_path"

unreadable_file="$source_path/DCIM/IMG_0083.DNG"
[[ -f "$unreadable_file" ]] || release_die "expected fixture file missing: $unreadable_file"
chmod 000 "$unreadable_file"

real_media_count="$(find "$source_path" -type f ! -name '.DS_Store' | wc -l | tr -d ' ')"
[[ "$real_media_count" -gt 1 ]] || release_die "expected multiple real media files in the cloned card"
readable_media_count=$((real_media_count - 1))

release_note "Running ingest with one unreadable file planted in the source..."
set +e
output="$("$binary" --source "$source_path" --dest "$dest_path" --json)"
command_exit=$?
set -e

[[ "$command_exit" == "0" ]] || release_die "a single unreadable file must not abort import (exit was $command_exit)"

final_json="$(print -r -- "$output" | jq -s '.[-1]')"

[[ "$(print -r -- "$final_json" | jq -r '.status_label')" == "VERIFIED" ]] || release_die "expected status_label=VERIFIED"
[[ "$(print -r -- "$final_json" | jq -r '.counts.errors')" == "1" ]] || release_die "expected errors=1 for the unreadable file"

candidates="$(print -r -- "$final_json" | jq -r '.counts.candidates')"
committed="$(print -r -- "$final_json" | jq -r '.counts.committed')"
[[ "$candidates" == "$readable_media_count" ]] || release_die "unreadable file must not be counted as a candidate (candidates=$candidates, expected=$readable_media_count)"
[[ "$committed" == "$readable_media_count" ]] || release_die "all readable media must still commit (committed=$committed, expected=$readable_media_count)"

# The unreadable file must remain untouched on the source card (no delete on card).
[[ -f "$unreadable_file" ]] || release_die "unreadable source file was removed"
current_perms="$(stat -f '%Lp' "$unreadable_file")"
[[ "$current_perms" == "0" ]] || release_die "unreadable source file permissions were modified (now $current_perms)"

receipt_path="$(print -r -- "$final_json" | jq -r '.receipt.path // empty')"
[[ -n "$receipt_path" && -f "$receipt_path" ]] || release_die "missing receipt path in final summary"

grep -q '"event_type":"ERROR"' "$receipt_path" || release_die "receipt missing ERROR event for unreadable file"
grep -q '"phase":"scan"' "$receipt_path" || release_die "receipt missing scan-phase event"
grep -q 'IMG_0083.DNG' "$receipt_path" || release_die "receipt does not reference the unreadable file's path"
grep -q '"error_count":1' "$receipt_path" || release_die "receipt SCAN_SUMMARY missing error_count:1"

release_note "Deterministic unreadable-source-file E2E check passed."
