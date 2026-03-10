#!/bin/zsh

set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/release-common.sh"

function usage() {
    cat <<'EOF'
Run local ingest smoke checks used by the release flow.

Usage:
  scripts/release-smoke-test.sh
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
fi

release_require_command swift
release_enable_swift_local_caches

source_one="$RELEASE_REPO_ROOT/Tests/TestingDirs/SD_CARD1"
source_two="$RELEASE_REPO_ROOT/Tests/TestingDirs/SD_CARD2"

[[ -d "$source_one" ]] || release_die "missing smoke source fixture: $source_one"
[[ -d "$source_two" ]] || release_die "missing smoke source fixture: $source_two"

binary="$RELEASE_REPO_ROOT/.build/debug/rollkeep"

if [[ ! -x "$binary" ]]; then
    release_note "Building debug rollkeep binary for smoke checks..."
    swift build --product rollkeep >/dev/null
fi

[[ -x "$binary" ]] || release_die "expected rollkeep binary not found at $binary"

temp_root="$(mktemp -d "${TMPDIR:-/tmp}/rollkeep-release-smoke.XXXXXX")"

function cleanup() {
    rm -rf "$temp_root"
}

trap cleanup EXIT

function assert_success_output() {
    local label="$1"
    local output="$2"

    print -r -- "$output" | grep -Eq '"status"[[:space:]]*:[[:space:]]*"completed"' || release_die "${label} did not complete successfully"
    print -r -- "$output" | grep -Eq '"status_label"[[:space:]]*:[[:space:]]*"VERIFIED"' || release_die "${label} did not report VERIFIED status"
    print -r -- "$output" | grep -Eq '"errors"[[:space:]]*:[[:space:]]*0' || release_die "${label} reported non-zero errors"
    print -r -- "$output" | grep -Eq '"receipt"[[:space:]]*:[[:space:]]*\{' || release_die "${label} did not report receipt details"
}

function run_first_pass() {
    local label="$1"
    local source_path="$2"
    local dest_path="$3"
    local output=""

    release_note "Running ${label} first-pass ingest..."
    if ! output="$("$binary" --source "$source_path" --dest "$dest_path" --json)"; then
        release_die "${label} ingest command failed"
    fi

    assert_success_output "$label first pass" "$output"
}

function run_duplicate_rerun() {
    local label="$1"
    local source_path="$2"
    local dest_path="$3"
    local output=""

    release_note "Running ${label} duplicate/rerun ingest..."
    if ! output="$("$binary" --source "$source_path" --dest "$dest_path" --json)"; then
        release_die "${label} duplicate/rerun command failed"
    fi

    print -r -- "$output" | grep -Eq '"status"[[:space:]]*:[[:space:]]*"completed"' || release_die "${label} duplicate/rerun did not complete successfully"
    print -r -- "$output" | grep -Eq '"duplicate_not_copied"[[:space:]]*:[[:space:]]*[1-9][0-9]*' || release_die "${label} duplicate/rerun did not detect duplicates"
    print -r -- "$output" | grep -Eq '"classification"[[:space:]]*:[[:space:]]*"idempotent_rerun"' || release_die "${label} duplicate/rerun did not report idempotent_rerun"
    print -r -- "$output" | grep -Eq '"errors"[[:space:]]*:[[:space:]]*0' || release_die "${label} duplicate/rerun reported non-zero errors"
}

dest_one="$temp_root/sd-card1-dest"
dest_two="$temp_root/sd-card2-dest"

mkdir -p "$dest_one" "$dest_two"

run_first_pass "SD_CARD1" "$source_one" "$dest_one"
run_duplicate_rerun "SD_CARD1" "$source_one" "$dest_one"

run_first_pass "SD_CARD2" "$source_two" "$dest_two"
run_duplicate_rerun "SD_CARD2" "$source_two" "$dest_two"

release_note "Local release smoke checks passed."
