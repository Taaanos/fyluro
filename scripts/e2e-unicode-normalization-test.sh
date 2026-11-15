#!/bin/zsh

set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/release-common.sh"

function usage() {
    cat <<'EOF'
Run Unicode-normalization collision E2E check (RT-P1-05, Unicode half).

Usage:
  scripts/e2e-unicode-normalization-test.sh

Verifies that a source filename encoded in NFD form (decomposed, e.g.
"e" + combining acute accent) is correctly recognized as the same visual
name as an NFC-encoded (precomposed) file already committed to the
destination, on all three real destination filesystems macOS ingest
targets support: HFS+, exFAT, and APFS.

This locks in a deliberately code-free finding: macOS normalizes
filenames at the VFS layer for all three filesystems, so the existing
fileManager.fileExists()-based duplicate/collision check in
StagingCommitEngine.resolveCommitPath already sees NFC and NFD spellings
of the same name as one file, with no dedicated normalization-folding
logic needed in rollkeep itself. See RT-P1-05 in
docs/red-team-ingest-test-matrix.md.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
fi

release_require_command swift
release_require_command jq
release_require_command python3
release_require_command hdiutil
release_enable_swift_local_caches

binary="$RELEASE_REPO_ROOT/.build/debug/rollkeep"
release_ensure_debug_rollkeep_binary "Unicode-normalization E2E"

nfc_name="$(python3 -c "import unicodedata,sys; sys.stdout.write(unicodedata.normalize('NFC','café.JPG'))")"
nfd_name="$(python3 -c "import unicodedata,sys; sys.stdout.write(unicodedata.normalize('NFD','café.JPG'))")"
[[ "$nfc_name" != "$nfd_name" ]] || release_die "NFC/NFD test filenames must differ in bytes"

temp_root="$(mktemp -d "${TMPDIR:-/tmp}/rollkeep-e2e-unicode.XXXXXX")"
mounted_volumes_file="$temp_root/.mounted_volumes"
: > "$mounted_volumes_file"

function cleanup() {
    local mount attempt
    if [[ -f "$mounted_volumes_file" ]]; then
        while IFS= read -r mount; do
            [[ -n "$mount" ]] || continue
            for attempt in 1 2 3 4 5; do
                hdiutil detach "$mount" -force -quiet 2>/dev/null && break
                sleep 1
            done
        done < "$mounted_volumes_file"
    fi
    rm -rf "$temp_root"
}
trap cleanup EXIT

function attach_volume() {
    local fs_type="$1"
    local label="$2"
    local image_path="$temp_root/${label}.dmg"
    local mount_point="$temp_root/${label}_mount"
    mkdir -p "$mount_point"
    hdiutil create -size 64m -fs "$fs_type" -volname "$label" "$image_path" -quiet
    hdiutil attach "$image_path" -mountpoint "$mount_point" -quiet
    # attach_volume's stdout is captured via $(...), which runs this whole
    # function in a subshell — an in-memory array append here would never be
    # visible to the parent shell's cleanup trap. Persist to a file instead.
    print -r -- "$mount_point" >> "$mounted_volumes_file"
    print -r -- "$mount_point"
}

function run_ingest() {
    local source_dir="$1"
    local dest_dir="$2"
    local output
    set +e
    output="$("$binary" --source "$source_dir" --dest "$dest_dir" --json)"
    local exit_code=$?
    set -e
    [[ "$exit_code" == "0" ]] || release_die "ingest failed unexpectedly (exit $exit_code) for source=$source_dir dest=$dest_dir: $output"
    print -r -- "$output" | jq -s '.[-1]'
}

function assert_field() {
    local json="$1"
    local field="$2"
    local expected="$3"
    local context="$4"
    local actual
    actual="$(print -r -- "$json" | jq -r "$field")"
    [[ "$actual" == "$expected" ]] || release_die "$context: expected $field=$expected, got $actual"
}

function scenario_for_filesystem() {
    local fs_type="$1"
    local label="$2"
    local dest_root
    dest_root="$(attach_volume "$fs_type" "$label")"
    local dest="$dest_root/dest"
    mkdir -p "$dest"

    release_note "[$label] committing NFC-named file '$nfc_name'..."
    local source1="$temp_root/${label}_source1"
    mkdir -p "$source1/DCIM"
    print -n "unicode-e2e-content-A" > "$source1/DCIM/$nfc_name"
    local result1
    result1="$(run_ingest "$source1" "$dest")"
    assert_field "$result1" ".counts.committed" "1" "[$label] first ingest (NFC)"
    assert_field "$result1" ".counts.errors" "0" "[$label] first ingest (NFC)"

    release_note "[$label] re-ingesting identical content under NFD-named file..."
    local source2="$temp_root/${label}_source2"
    mkdir -p "$source2/DCIM"
    print -n "unicode-e2e-content-A" > "$source2/DCIM/$nfd_name"
    local result2
    result2="$(run_ingest "$source2" "$dest")"
    assert_field "$result2" ".counts.committed" "0" "[$label] duplicate ingest (NFD, same bytes)"
    assert_field "$result2" ".counts.duplicate_not_copied" "1" "[$label] duplicate ingest (NFD, same bytes)"

    local real_file_count
    real_file_count="$(find "$dest" -type f -iname '*.JPG' ! -name '._*' | wc -l | tr -d ' ')"
    [[ "$real_file_count" == "1" ]] || release_die "[$label] expected exactly 1 committed photo after duplicate ingest, found $real_file_count"

    release_note "[$label] ingesting different content under NFD-named file (real collision)..."
    local source3="$temp_root/${label}_source3"
    mkdir -p "$source3/DCIM"
    print -n "unicode-e2e-content-B" > "$source3/DCIM/$nfd_name"
    local result3
    result3="$(run_ingest "$source3" "$dest")"
    assert_field "$result3" ".counts.committed" "1" "[$label] conflict ingest (NFD, different bytes)"
    assert_field "$result3" ".counts.conflicts_renamed" "1" "[$label] conflict ingest (NFD, different bytes)"

    real_file_count="$(find "$dest" -type f -iname '*.JPG' ! -name '._*' | wc -l | tr -d ' ')"
    [[ "$real_file_count" == "2" ]] || release_die "[$label] expected exactly 2 photos after conflict ingest, found $real_file_count"

    local original_content
    original_content="$(find "$dest" -type f -iname '*.JPG' ! -name '._*' ! -iname '*-1.JPG' -exec cat {} \;)"
    [[ "$original_content" == "unicode-e2e-content-A" ]] || release_die "[$label] original file content changed: overwrite occurred"

    local renamed_content
    renamed_content="$(find "$dest" -type f -iname '*-1.JPG' ! -name '._*' -exec cat {} \;)"
    [[ "$renamed_content" == "unicode-e2e-content-B" ]] || release_die "[$label] renamed conflict file missing or has wrong content"

    release_note "[$label] Unicode-normalization collision handled safely (no overwrite, correct dedup/rename)."
}

scenario_for_filesystem "HFS+" "hfs"
scenario_for_filesystem "ExFAT" "exfat"
scenario_for_filesystem "APFS" "apfs"

release_note "Unicode-normalization collision E2E check passed on HFS+, exFAT, and APFS."
