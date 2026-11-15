#!/bin/zsh

set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/release-common.sh"

function usage() {
    cat <<'EOF'
Run deterministic fault-injection E2E checks for:
  - destination disconnect during copy/commit
  - disk full during copy
  - receipt failover from destination to local temp

Usage:
  scripts/e2e-fault-injection-test.sh
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
release_ensure_debug_rollkeep_binary "fault-injection E2E"

source_fixture="$RELEASE_REPO_ROOT/Tests/TestingDirs/SD_CARD1"
[[ -d "$source_fixture" ]] || release_die "missing source fixture: $source_fixture"

temp_root="$(mktemp -d "${TMPDIR:-/tmp}/rollkeep-e2e-fault-injection.XXXXXX")"

function cleanup() {
    rm -rf "$temp_root"
}
trap cleanup EXIT

function extract_final_json() {
    local output="$1"
    print -r -- "$output" | jq -s '.[-1]'
}

function assert_failure_result() {
    local label="$1"
    local final_json="$2"
    local expected_phase="$3"

    [[ "$(print -r -- "$final_json" | jq -r '.status')" == "aborted" ]] || release_die "${label}: expected status=aborted"
    [[ "$(print -r -- "$final_json" | jq -r '.status_label')" == "FAILED" ]] || release_die "${label}: expected status_label=FAILED"
    [[ "$(print -r -- "$final_json" | jq -r '.failure.phase')" == "$expected_phase" ]] || release_die "${label}: expected failure.phase=$expected_phase"

    local receipt_path
    receipt_path="$(print -r -- "$final_json" | jq -r '.receipt.path // empty')"
    [[ -n "$receipt_path" ]] || release_die "${label}: missing receipt path"
    [[ -f "$receipt_path" ]] || release_die "${label}: receipt file missing at $receipt_path"
    grep -q '"event_type":"SESSION_STARTED"' "$receipt_path" || release_die "${label}: receipt missing SESSION_STARTED"
    grep -q '"event_type":"ERROR"' "$receipt_path" || release_die "${label}: receipt missing ERROR event"
    grep -q '"event_type":"SESSION_FINISHED"' "$receipt_path" || release_die "${label}: receipt missing SESSION_FINISHED"

    local staging_path
    staging_path="$(print -r -- "$final_json" | jq -r '.staging_session_path // empty')"
    [[ -n "$staging_path" ]] || release_die "${label}: missing staging_session_path"
    [[ -d "$staging_path" ]] || release_die "${label}: staging path should be retained on failure"
}

function run_copy_disconnect_failure() {
    local dest="$temp_root/dest-copy-disconnect"
    mkdir -p "$dest"

    release_note "Running E2E-015 copy-phase disconnect failure simulation..."
    local output=""
    local command_exit=0
    set +e
    output="$(
        ROLLKEEP_TEST_FAIL_COPY_ON_NTH_FILE=2 \
        ROLLKEEP_TEST_FAIL_COPY_ERROR_MESSAGE="Simulated destination disconnect during copy" \
        "$binary" --source "$source_fixture" --dest "$dest" --json --max-parallel-copies 1
    )"
    command_exit=$?
    set -e
    [[ "$command_exit" != "0" ]] || release_die "E2E-015 copy disconnect: expected non-zero exit"

    local final_json
    final_json="$(extract_final_json "$output")"
    assert_failure_result "E2E-015 copy disconnect" "$final_json" "copy"
}

function run_commit_disconnect_failure() {
    local dest="$temp_root/dest-commit-disconnect"
    mkdir -p "$dest"

    release_note "Running E2E-015 commit-phase disconnect failure simulation..."
    local output=""
    local command_exit=0
    set +e
    output="$(
        ROLLKEEP_TEST_FAIL_COMMIT_ON_NTH_FILE=1 \
        ROLLKEEP_TEST_FAIL_COMMIT_ERROR_MESSAGE="Simulated destination disconnect during commit" \
        "$binary" --source "$source_fixture" --dest "$dest" --json --max-parallel-copies 1
    )"
    command_exit=$?
    set -e
    [[ "$command_exit" != "0" ]] || release_die "E2E-015 commit disconnect: expected non-zero exit"

    local final_json
    final_json="$(extract_final_json "$output")"
    assert_failure_result "E2E-015 commit disconnect" "$final_json" "commit"

    local receipt_path
    receipt_path="$(print -r -- "$final_json" | jq -r '.receipt.path // empty')"
    grep -q '"event_type":"FILE_COMMIT_STARTED"' "$receipt_path" || release_die "E2E-015 commit disconnect: missing FILE_COMMIT_STARTED"
}

function run_disk_full_failure() {
    local dest="$temp_root/dest-disk-full"
    mkdir -p "$dest"

    release_note "Running E2E-016 disk-full failure simulation..."
    local output=""
    local command_exit=0
    set +e
    output="$(
        ROLLKEEP_TEST_FAIL_COPY_ON_NTH_FILE=2 \
        ROLLKEEP_TEST_FAIL_COPY_ERROR_MESSAGE="No space left on device (simulated ENOSPC)" \
        "$binary" --source "$source_fixture" --dest "$dest" --json --max-parallel-copies 1
    )"
    command_exit=$?
    set -e
    [[ "$command_exit" != "0" ]] || release_die "E2E-016 disk full: expected non-zero exit"

    local final_json
    final_json="$(extract_final_json "$output")"
    assert_failure_result "E2E-016 disk full" "$final_json" "copy"
    print -r -- "$final_json" | jq -e '.failure.reason | contains("No space left on device")' >/dev/null || release_die "E2E-016 disk full: failure reason missing ENOSPC signal"
}

function run_receipt_failover() {
    local dest="$temp_root/dest-receipt-failover"
    mkdir -p "$dest"

    release_note "Running E2E-017 receipt failover simulation..."
    local output=""
    if ! output="$(
        ROLLKEEP_TEST_RECEIPT_FAIL_DEST_APPEND_AT_EVENT_INDEX=3 \
        "$binary" --source "$source_fixture" --dest "$dest" --json --max-parallel-copies 1
    )"; then
        release_die "E2E-017 receipt failover command failed unexpectedly"
    fi

    local final_json
    final_json="$(extract_final_json "$output")"
    [[ "$(print -r -- "$final_json" | jq -r '.status')" == "completed" ]] || release_die "E2E-017 receipt failover: expected status=completed"
    [[ "$(print -r -- "$final_json" | jq -r '.status_label')" == "VERIFIED" ]] || release_die "E2E-017 receipt failover: expected status_label=VERIFIED"
    [[ "$(print -r -- "$final_json" | jq -r '.receipt.sink')" == "localFallback" ]] || release_die "E2E-017 receipt failover: expected final receipt sink localFallback"

    local fallback_receipt_path
    fallback_receipt_path="$(print -r -- "$final_json" | jq -r '.receipt.path // empty')"
    [[ -n "$fallback_receipt_path" ]] || release_die "E2E-017 receipt failover: missing fallback receipt path"
    [[ -f "$fallback_receipt_path" ]] || release_die "E2E-017 receipt failover: fallback receipt missing at $fallback_receipt_path"

    local summary_event
    summary_event="$(jq -s 'map(select(.event_type=="SUMMARY")) | last' "$fallback_receipt_path")"
    [[ "$summary_event" != "null" ]] || release_die "E2E-017 receipt failover: missing SUMMARY event in fallback receipt"

    local transition_count receipt_paths_count destination_receipt_path
    transition_count="$(print -r -- "$summary_event" | jq -r '.data.receipt_sink_transitions | length')"
    receipt_paths_count="$(print -r -- "$summary_event" | jq -r '.data.receipt_paths | length')"
    [[ "$transition_count" -ge 1 ]] || release_die "E2E-017 receipt failover: expected at least one sink transition"
    [[ "$receipt_paths_count" -ge 2 ]] || release_die "E2E-017 receipt failover: expected destination and fallback receipt paths"
    print -r -- "$summary_event" | jq -e '.data.receipt_sink_transitions[0].reason == "destination_receipt_append_failed"' >/dev/null || release_die "E2E-017 receipt failover: unexpected sink transition reason"

    destination_receipt_path="$(print -r -- "$summary_event" | jq -r '.data.receipt_paths[] | select(.kind=="destination") | .path' | head -n1)"
    [[ -n "$destination_receipt_path" ]] || release_die "E2E-017 receipt failover: missing destination receipt path in summary"
    [[ -f "$destination_receipt_path" ]] || release_die "E2E-017 receipt failover: destination receipt file missing at $destination_receipt_path"
}

run_copy_disconnect_failure
run_commit_disconnect_failure
run_disk_full_failure
run_receipt_failover

release_note "Deterministic fault-injection E2E checks passed."
