#!/bin/zsh

set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/release-common.sh"

function usage() {
    cat <<'EOF'
Time-boxed check for hostile source filenames beyond symlinks (RT-P2-04 / E2E-042):
a max-length filename, a Unicode RTL-override extension-spoofing filename, and a
control-character/ANSI-injection filename, on a real disk image.

Uses HFS+ rather than exFAT (the more realistic SD-card format): this
environment's exFAT/FAT-family hdiutil driver was observed to fail
"Operation not permitted" persistently (not transient -- 5+ retries with
backoff still failed) while HFS+ creation succeeded reliably every time, a
localized environment/driver issue unrelated to rollkeep. The code paths
under test (extension-based media-type classification in
SourceScannerTraversal.swift, scan candidate counting, human-vs-JSON-mode
output escaping) are filesystem-agnostic Swift/Foundation logic with no
HFS+-specific branches, so this substitution does not weaken what's being
verified. exFAT/APFS are not re-tested here since this is a secondary,
lower-priority check -- re-run on exFAT in an environment where that
driver behaves, if a filesystem-specific difference is ever suspected.

Usage:
  scripts/e2e-hostile-filenames-test.sh
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

binary="$RELEASE_REPO_ROOT/.build/debug/rollkeep"
release_ensure_debug_rollkeep_binary "hostile-filenames E2E"

# (a) Max-length filename: exFAT/HFS+/APFS all cap at 255 UTF-16 code units
# per path component.
max_len_name="$(python3 -c "print('L' * 250 + '.jpg')")"

# (b) RTL-override extension-spoofing: true trailing extension is really
# ".mp4" (so rollkeep should classify it as a video), but a U+202E
# (RIGHT-TO-LEFT OVERRIDE) earlier in the name makes a terminal/renderer
# display the tail reversed, visually suggesting a different extension.
rtl_name="$(python3 -c "print('IMG_1234' + '‮' + '4pm.gpj' + '.mp4')")"

# (c) Raw control character / ANSI escape sequence in a filename.
control_name="$(python3 -c "print('IMG_' + '\x1b[2J\x1b[31mHACKED\x1b[0m' + '_5678.jpg')")"

temp_root="$(mktemp -d "${TMPDIR:-/tmp}/rollkeep-e2e-hostile-names.XXXXXX")"
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

    # hdiutil's exFAT/FAT-family disk-image creation has been observed to
    # fail intermittently with "Operation not permitted" for no discernible
    # reason (not tied to volume name, casing, or TMPDIR location -- retrying
    # the identical command shortly after often succeeds). Retry rather than
    # fail the whole check on a transient hiccup.
    local attempt
    local created=0
    for attempt in 1 2 3 4 5; do
        if hdiutil create -size 64m -fs "$fs_type" -volname "$label" "$image_path" -quiet 2>/dev/null; then
            created=1
            break
        fi
        release_note "hdiutil create attempt $attempt failed, retrying..."
        sleep 2
    done
    (( created )) || release_die "hdiutil create failed after 5 attempts (transient environment issue, not a rollkeep bug)"

    hdiutil attach "$image_path" -mountpoint "$mount_point" -quiet
    print -r -- "$mount_point" >> "$mounted_volumes_file"
    print -r -- "$mount_point"
}

dest_root="$(attach_volume "HFS+" "hostilenames")"
dcim="$dest_root/DCIM"
mkdir -p "$dcim"

print -n "fake-jpeg-bytes-max-length" > "$dcim/$max_len_name"
print -n "fake-mp4-bytes-rtl-spoof" > "$dcim/$rtl_name"
print -n "fake-jpeg-bytes-control-char" > "$dcim/$control_name"

created_count="$(find "$dcim" -type f | wc -l | tr -d ' ')"
release_note "Created $created_count hostile-named files on HFS+."
[[ "$created_count" == "3" ]] || release_die "expected 3 hostile-named files to be created, filesystem accepted $created_count"

dest="$temp_root/dest"
mkdir -p "$dest"

release_note "Running JSON-mode dry-run scan..."
json_output="$("$binary" --source "$dest_root" --dest "$dest" --json --dry-run)"
candidate_count="$(print -r -- "$json_output" | jq -s '.[-1].counts.candidates')"
release_note "Candidates scanned: $candidate_count (expected 3, no silent drop)"
[[ "$candidate_count" == "3" ]] || release_die "expected all 3 hostile-named files to be scanned as candidates, got $candidate_count"

# The RTL-override file's TRUE trailing extension is ".mp4" -- confirm it is
# classified as a video (not fooled into being treated as a photo by the
# visually-spoofed tail), i.e. exactly 1 of the 3 candidates is a video.
video_count="$(print -r -- "$json_output" | jq -s '.[-1].counts.videos')"
release_note "Videos scanned: $video_count (expected 1 -- the RTL-override file's true .mp4 extension)"
[[ "$video_count" == "1" ]] || release_die "expected the RTL-override file to be classified as a video by its true extension, got video_count=$video_count"

# JSON output must not contain a literal unescaped control byte (standard
# JSON string escaping is expected to handle this by construction). macOS's
# BSD grep has no -P, so match the raw ESC byte via ANSI-C quoting instead.
if print -r -- "$json_output" | grep -q $'\x1b'; then
    release_die "JSON output contains a literal unescaped ESC byte -- JSON encoding should have escaped it"
fi
release_note "[json mode] no literal unescaped control bytes found (escaped correctly)."

release_note "Running human-mode dry-run scan..."
human_output="$("$binary" --source "$dest_root" --dest "$dest" --dry-run 2>&1 || true)"

if print -r -- "$human_output" | grep -qF $'\x1b[2J' || print -r -- "$human_output" | grep -qF $'\x1b[31m'; then
    release_note "[finding] raw ANSI escape sequence bytes from the hostile filename reach human-mode terminal output unescaped -- a filename containing ANSI codes can control the terminal when a human reviews \`rollkeep\` output without --json."
else
    release_note "[info] raw ANSI escape sequence bytes were not found literally in captured human-mode output (may have been escaped, or captured differently outside an interactive TTY)."
fi

if print -r -- "$human_output" | grep -q '‮'; then
    release_note "[info] raw U+202E override character reaches human-mode terminal output unescaped -- filenames can visually spoof their real extension in any plain-text review context (receipts, terminal, logs)."
fi

release_note "Hostile-filenames E2E check complete (see notes above for results)."
