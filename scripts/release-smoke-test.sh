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
release_require_command jq
release_require_command shasum
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

function extract_final_json() {
    local output="$1"
    print -r -- "$output" | jq -s '.[-1]'
}

function assert_receipt_integrity() {
    local label="$1"
    local final_json="$2"
    local receipt_path=""

    receipt_path="$(print -r -- "$final_json" | jq -r '.receipt.path // empty')"
    [[ -n "$receipt_path" ]] || release_die "${label} did not expose a receipt path"
    [[ -f "$receipt_path" ]] || release_die "${label} receipt file missing at $receipt_path"

    grep -q '"event_type":"SESSION_STARTED"' "$receipt_path" || release_die "${label} receipt missing SESSION_STARTED"
    grep -q '"event_type":"SESSION_FINISHED"' "$receipt_path" || release_die "${label} receipt missing SESSION_FINISHED"
}

function assert_success_output() {
    local label="$1"
    local final_json="$2"

    [[ "$(print -r -- "$final_json" | jq -r '.status')" == "completed" ]] || release_die "${label} did not complete successfully"
    [[ "$(print -r -- "$final_json" | jq -r '.status_label')" == "VERIFIED" ]] || release_die "${label} did not report VERIFIED status"
    [[ "$(print -r -- "$final_json" | jq -r '.counts.errors')" == "0" ]] || release_die "${label} reported non-zero errors"
    assert_receipt_integrity "$label" "$final_json"
}

function write_source_manifest() {
    local source_path="$1"
    local output_path="$2"

    (
        cd "$source_path"
        find . -type f -print0 | sort -z | while IFS= read -r -d '' rel_path; do
            local normalized="${rel_path#./}"
            local mtime size hash
            mtime="$(stat -f '%m' "$normalized")"
            size="$(stat -f '%z' "$normalized")"
            hash="$(shasum -a 256 "$normalized" | awk '{print $1}')"
            printf '%s\t%s\t%s\t%s\n' "$normalized" "$size" "$mtime" "$hash"
        done
    ) > "$output_path"
}

function assert_source_immutable() {
    local label="$1"
    local before_manifest="$2"
    local after_manifest="$3"

    if ! diff -u "$before_manifest" "$after_manifest" >/dev/null; then
        release_die "${label} source fixture mutated during ingest"
    fi
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

    local final_json=""
    final_json="$(extract_final_json "$output")"

    assert_success_output "$label first pass" "$final_json"
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

    local final_json=""
    final_json="$(extract_final_json "$output")"

    [[ "$(print -r -- "$final_json" | jq -r '.status')" == "completed" ]] || release_die "${label} duplicate/rerun did not complete successfully"
    [[ "$(print -r -- "$final_json" | jq -r '.counts.duplicate_not_copied')" != "0" ]] || release_die "${label} duplicate/rerun did not detect duplicates"
    [[ "$(print -r -- "$final_json" | jq -r '.idempotency.classification')" == "idempotent_rerun" ]] || release_die "${label} duplicate/rerun did not report idempotent_rerun"
    [[ "$(print -r -- "$final_json" | jq -r '.counts.errors')" == "0" ]] || release_die "${label} duplicate/rerun reported non-zero errors"
    assert_receipt_integrity "${label} duplicate/rerun" "$final_json"
}

dest_one="$temp_root/sd-card1-dest"
dest_two="$temp_root/sd-card2-dest"

mkdir -p "$dest_one" "$dest_two"

source_one_before="$temp_root/source-one-before.tsv"
source_one_after="$temp_root/source-one-after.tsv"
source_two_before="$temp_root/source-two-before.tsv"
source_two_after="$temp_root/source-two-after.tsv"

release_note "Capturing pre-run source manifests..."
write_source_manifest "$source_one" "$source_one_before"
write_source_manifest "$source_two" "$source_two_before"

run_first_pass "SD_CARD1" "$source_one" "$dest_one"
run_duplicate_rerun "SD_CARD1" "$source_one" "$dest_one"

run_first_pass "SD_CARD2" "$source_two" "$dest_two"
run_duplicate_rerun "SD_CARD2" "$source_two" "$dest_two"

release_note "Capturing post-run source manifests..."
write_source_manifest "$source_one" "$source_one_after"
write_source_manifest "$source_two" "$source_two_after"

assert_source_immutable "SD_CARD1" "$source_one_before" "$source_one_after"
assert_source_immutable "SD_CARD2" "$source_two_before" "$source_two_after"

release_note "Local release smoke checks passed."
