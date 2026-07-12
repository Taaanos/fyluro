#!/bin/zsh

set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/release-common.sh"

function usage() {
    cat <<'EOF'
Run deterministic verify-failure E2E check.

Usage:
  scripts/e2e-verify-failure-test.sh
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
if [[ ! -x "$binary" ]]; then
    release_note "Building debug rollkeep binary for verify-failure E2E..."
    swift build --product rollkeep >/dev/null
fi
[[ -x "$binary" ]] || release_die "expected rollkeep binary not found at $binary"

source_fixture="$RELEASE_REPO_ROOT/Tests/TestingDirs/SD_CARD1/DCIM/IMG_8236.HEIC"
[[ -f "$source_fixture" ]] || release_die "missing source fixture: $source_fixture"

temp_root="$(mktemp -d "${TMPDIR:-/tmp}/rollkeep-e2e-verify-fail.XXXXXX")"
source_path="$temp_root/source"
dest_path="$temp_root/dest"

function cleanup() {
    rm -rf "$temp_root"
}

trap cleanup EXIT

mkdir -p "$source_path/DCIM" "$dest_path"
cp "$source_fixture" "$source_path/DCIM/"

release_note "Running verify-failure ingest with deterministic corruption hook..."
set +e
output="$(ROLLKEEP_TEST_CORRUPT_STAGING_BEFORE_VERIFY=1 "$binary" --source "$source_path" --dest "$dest_path" --json --max-parallel-copies 1)"
command_exit=$?
set -e

[[ "$command_exit" != "0" ]] || release_die "expected non-zero exit for verify failure scenario"

final_json="$(print -r -- "$output" | jq -s '.[-1]')"

[[ "$(print -r -- "$final_json" | jq -r '.status')" == "aborted" ]] || release_die "expected status=aborted"
[[ "$(print -r -- "$final_json" | jq -r '.status_label')" == "FAILED" ]] || release_die "expected status_label=FAILED"
[[ "$(print -r -- "$final_json" | jq -r '.failure.phase')" == "verify" ]] || release_die "expected failure.phase=verify"
[[ "$(print -r -- "$final_json" | jq -r '.counts.committed')" == "0" ]] || release_die "expected committed=0 on verify failure"

receipt_path="$(print -r -- "$final_json" | jq -r '.receipt.path // empty')"
[[ -n "$receipt_path" ]] || release_die "missing receipt path in final summary"
[[ -f "$receipt_path" ]] || release_die "receipt file not found: $receipt_path"

grep -q '"event_type":"FILE_VERIFY_STARTED"' "$receipt_path" || release_die "receipt missing FILE_VERIFY_STARTED event"
grep -q '"event_type":"FILE_VERIFIED"' "$receipt_path" || release_die "receipt missing FILE_VERIFIED failure event"
if grep -q '"event_type":"FILE_COMMIT_STARTED"' "$receipt_path"; then
    release_die "receipt should not contain FILE_COMMIT_STARTED after verify failure"
fi

staging_path="$(print -r -- "$final_json" | jq -r '.staging_session_path // empty')"
[[ -n "$staging_path" ]] || release_die "missing staging_session_path in final summary"
[[ -d "$staging_path" ]] || release_die "staging session path should be retained on verify failure: $staging_path"

release_note "Deterministic verify-failure E2E check passed."
