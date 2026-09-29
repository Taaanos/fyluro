#!/bin/zsh

set -euo pipefail

typeset -gr RELEASE_SCRIPT_DIR="$(cd "$(dirname "${(%):-%N}")" && pwd)"
typeset -gr RELEASE_REPO_ROOT="$(cd "$RELEASE_SCRIPT_DIR/.." && pwd)"
typeset -gr RELEASE_VERSION_FILE="$RELEASE_REPO_ROOT/VERSION"
typeset -gr RELEASE_CHANGELOG_FILE="$RELEASE_REPO_ROOT/CHANGELOG.md"
typeset -gr RELEASE_CHANGELOG_MARKER="<!-- release-sections -->"
typeset -gr RELEASE_APP_NAME="RollKeep"
typeset -gr RELEASE_ARCH="arm64"
typeset -gr RELEASE_SWIFT_HOME="$RELEASE_REPO_ROOT/.tmp/home"
typeset -gr RELEASE_SWIFT_TMPDIR="$RELEASE_REPO_ROOT/.tmp/tmpdir"
typeset -gr RELEASE_SWIFT_CLANG_CACHE="$RELEASE_REPO_ROOT/.tmp/clang-module-cache"
typeset -gr RELEASE_SWIFT_PACKAGE_CACHE="$RELEASE_REPO_ROOT/.tmp/swiftpm-cache"
typeset -gr RELEASE_SWIFT_CONFIG_DIR="$RELEASE_REPO_ROOT/.tmp/swiftpm-config"
typeset -gr RELEASE_SWIFT_SECURITY_DIR="$RELEASE_REPO_ROOT/.tmp/swiftpm-security"

# Automated runs must never read a developer's real camera catalog
# (ROL-6 Section 6): point it at a path that doesn't exist (= empty catalog).
export ROLLKEEP_CAMERA_CATALOG_PATH="${ROLLKEEP_CAMERA_CATALOG_PATH:-$RELEASE_REPO_ROOT/.tmp/no-camera-catalog.json}"

function release_die() {
    echo "error: $*" >&2
    exit 1
}

function release_note() {
    echo "$*" >&2
}

function release_require_command() {
    local command_name="$1"
    command -v "$command_name" >/dev/null 2>&1 || release_die "required command not found: $command_name"
}

function release_validate_version() {
    local version="$1"
    [[ "$version" == <->.<->.<-> ]] || release_die "version must use semver x.y.z format"
}

function release_read_version() {
    [[ -f "$RELEASE_VERSION_FILE" ]] || release_die "missing VERSION file at $RELEASE_VERSION_FILE"
    local version
    version="$(<"$RELEASE_VERSION_FILE")"
    version="${version//$'\n'/}"
    release_validate_version "$version"
    print -- "$version"
}

function release_write_version() {
    local version="$1"
    release_validate_version "$version"
    print -- "$version" > "$RELEASE_VERSION_FILE"
}

function release_bump_version() {
    local version="$1"
    local bump="$2"
    release_validate_version "$version"

    local -a parts
    parts=("${(@s:.:)version}")

    local -i major="${parts[1]}"
    local -i minor="${parts[2]}"
    local -i patch="${parts[3]}"

    case "$bump" in
        major)
            (( major += 1 ))
            minor=0
            patch=0
            ;;
        minor)
            (( minor += 1 ))
            patch=0
            ;;
        patch)
            (( patch += 1 ))
            ;;
        *)
            release_die "unsupported bump type: $bump"
            ;;
    esac

    print -- "${major}.${minor}.${patch}"
}

function release_release_tag() {
    local version="$1"
    release_validate_version "$version"
    print -- "v${version}"
}

function release_latest_tag() {
    git -C "$RELEASE_REPO_ROOT" describe --tags --abbrev=0 --match 'v[0-9]*' 2>/dev/null || true
}

function release_log_range() {
    local previous_tag="$1"
    if [[ -n "$previous_tag" ]]; then
        print -- "${previous_tag}..HEAD"
    else
        print -- "HEAD"
    fi
}

function release_require_clean_git() {
    local git_status
    git_status="$(git -C "$RELEASE_REPO_ROOT" status --short)"
    [[ -z "$git_status" ]] || release_die "git working tree must be clean before running the release flow"
}

function release_current_branch() {
    git -C "$RELEASE_REPO_ROOT" branch --show-current
}

function release_enable_swift_local_caches() {
    mkdir -p \
        "$RELEASE_SWIFT_HOME/Library/Caches/org.swift.swiftpm" \
        "$RELEASE_SWIFT_HOME/Library/org.swift.swiftpm/configuration" \
        "$RELEASE_SWIFT_HOME/Library/org.swift.swiftpm/security" \
        "$RELEASE_SWIFT_TMPDIR" \
        "$RELEASE_SWIFT_CLANG_CACHE" \
        "$RELEASE_SWIFT_PACKAGE_CACHE" \
        "$RELEASE_SWIFT_CONFIG_DIR" \
        "$RELEASE_SWIFT_SECURITY_DIR"

    export HOME="$RELEASE_SWIFT_HOME"
    export TMPDIR="$RELEASE_SWIFT_TMPDIR"
    export CLANG_MODULE_CACHE_PATH="$RELEASE_SWIFT_CLANG_CACHE"
    export SWIFTPM_CUSTOM_CACHE_PATH="$RELEASE_SWIFT_PACKAGE_CACHE"
    export SWIFTPM_ENABLE_PLUGINS=0
}

function release_zip_path() {
    local version="$1"
    release_validate_version "$version"
    print -- "$RELEASE_REPO_ROOT/dist/${RELEASE_APP_NAME}-${version}-macos-${RELEASE_ARCH}.zip"
}

function release_checksum_path() {
    local version="$1"
    release_validate_version "$version"
    print -- "$(release_zip_path "$version").sha256"
}

function release_app_bundle_path() {
    print -- "$RELEASE_REPO_ROOT/dist/${RELEASE_APP_NAME}.app"
}

function release_smoke_extract_final_json() {
    local output="$1"
    print -r -- "$output" | jq -s '.[-1]'
}

function release_smoke_assert_receipt_integrity() {
    local label="$1"
    local final_json="$2"
    local receipt_path=""

    receipt_path="$(print -r -- "$final_json" | jq -r '.receipt.path // empty')"
    [[ -n "$receipt_path" ]] || release_die "${label} did not expose a receipt path"
    [[ -f "$receipt_path" ]] || release_die "${label} receipt file missing at $receipt_path"

    grep -q '"event_type":"SESSION_STARTED"' "$receipt_path" || release_die "${label} receipt missing SESSION_STARTED"
    grep -q '"event_type":"SESSION_FINISHED"' "$receipt_path" || release_die "${label} receipt missing SESSION_FINISHED"
}

function release_smoke_assert_success_output() {
    local label="$1"
    local final_json="$2"

    [[ "$(print -r -- "$final_json" | jq -r '.status')" == "completed" ]] || release_die "${label} did not complete successfully"
    [[ "$(print -r -- "$final_json" | jq -r '.status_label')" == "VERIFIED" ]] || release_die "${label} did not report VERIFIED status"
    [[ "$(print -r -- "$final_json" | jq -r '.counts.errors')" == "0" ]] || release_die "${label} reported non-zero errors"
    release_smoke_assert_receipt_integrity "$label" "$final_json"
}

function release_smoke_write_source_manifest() {
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

function release_smoke_assert_source_immutable() {
    local label="$1"
    local before_manifest="$2"
    local after_manifest="$3"

    if ! diff -u "$before_manifest" "$after_manifest" >/dev/null; then
        release_die "${label} source fixture mutated during ingest"
    fi
}

function release_smoke_run_first_pass() {
    local label="$1"
    local binary="$2"
    local source_path="$3"
    local dest_path="$4"
    local output=""

    release_note "Running ${label} first-pass ingest..."
    if ! output="$("$binary" --source "$source_path" --dest "$dest_path" --json)"; then
        release_die "${label} ingest command failed"
    fi

    local final_json=""
    final_json="$(release_smoke_extract_final_json "$output")"

    release_smoke_assert_success_output "${label} first pass" "$final_json"
}

function release_smoke_run_duplicate_rerun() {
    local label="$1"
    local binary="$2"
    local source_path="$3"
    local dest_path="$4"
    local output=""

    release_note "Running ${label} duplicate/rerun ingest..."
    if ! output="$("$binary" --source "$source_path" --dest "$dest_path" --json)"; then
        release_die "${label} duplicate/rerun command failed"
    fi

    local final_json=""
    final_json="$(release_smoke_extract_final_json "$output")"

    [[ "$(print -r -- "$final_json" | jq -r '.status')" == "completed" ]] || release_die "${label} duplicate/rerun did not complete successfully"
    [[ "$(print -r -- "$final_json" | jq -r '.counts.duplicate_not_copied')" != "0" ]] || release_die "${label} duplicate/rerun did not detect duplicates"
    [[ "$(print -r -- "$final_json" | jq -r '.idempotency.classification')" == "idempotent_rerun" ]] || release_die "${label} duplicate/rerun did not report idempotent_rerun"
    [[ "$(print -r -- "$final_json" | jq -r '.counts.errors')" == "0" ]] || release_die "${label} duplicate/rerun reported non-zero errors"
    release_smoke_assert_receipt_integrity "${label} duplicate/rerun" "$final_json"
}

# Runs the full SD_CARD1/SD_CARD2 ingest-and-verify flow (first pass,
# duplicate rerun, source-immutability check) against the given rollkeep
# CLI binary. Shared by release-smoke-test.sh (runs against the raw debug
# binary) and release-app-smoke-test.sh (runs against the actual packaged
# .app, relocated outside the repo) so both exercise identical assertions
# against whichever binary they're handed.
function release_smoke_run_ingest_fixture_suite() {
    local binary="$1"
    local temp_root="$2"

    local source_one="$RELEASE_REPO_ROOT/Tests/TestingDirs/SD_CARD1"
    local source_two="$RELEASE_REPO_ROOT/Tests/TestingDirs/SD_CARD2"

    [[ -d "$source_one" ]] || release_die "missing smoke source fixture: $source_one"
    [[ -d "$source_two" ]] || release_die "missing smoke source fixture: $source_two"
    [[ -x "$binary" ]] || release_die "expected rollkeep binary not found at $binary"

    local dest_one="$temp_root/sd-card1-dest"
    local dest_two="$temp_root/sd-card2-dest"
    mkdir -p "$dest_one" "$dest_two"

    local source_one_before="$temp_root/source-one-before.tsv"
    local source_one_after="$temp_root/source-one-after.tsv"
    local source_two_before="$temp_root/source-two-before.tsv"
    local source_two_after="$temp_root/source-two-after.tsv"

    release_note "Capturing pre-run source manifests..."
    release_smoke_write_source_manifest "$source_one" "$source_one_before"
    release_smoke_write_source_manifest "$source_two" "$source_two_before"

    release_smoke_run_first_pass "SD_CARD1" "$binary" "$source_one" "$dest_one"
    release_smoke_run_duplicate_rerun "SD_CARD1" "$binary" "$source_one" "$dest_one"

    release_smoke_run_first_pass "SD_CARD2" "$binary" "$source_two" "$dest_two"
    release_smoke_run_duplicate_rerun "SD_CARD2" "$binary" "$source_two" "$dest_two"

    release_note "Capturing post-run source manifests..."
    release_smoke_write_source_manifest "$source_one" "$source_one_after"
    release_smoke_write_source_manifest "$source_two" "$source_two_after"

    release_smoke_assert_source_immutable "SD_CARD1" "$source_one_before" "$source_one_after"
    release_smoke_assert_source_immutable "SD_CARD2" "$source_two_before" "$source_two_after"
}

function release_verify_assets() {
    local version="$1"
    local zip_path checksum_path
    zip_path="$(release_zip_path "$version")"
    checksum_path="$(release_checksum_path "$version")"

    [[ -f "$zip_path" ]] || release_die "missing release archive: $zip_path"
    [[ -f "$checksum_path" ]] || release_die "missing release checksum: $checksum_path"
}

function release_emit_bullets() {
    local title="$1"
    shift

    (( $# == 0 )) && return

    print -- "### $title"
    print

    local item
    for item in "$@"; do
        print -- "- $item"
    done

    print
}

function release_render_changelog_section() {
    local version="$1"
    local previous_tag="$2"
    local range="$3"
    local release_date
    release_date="$(date +%F)"

    local -a added=()
    local -a fixed=()
    local -a changed=()
    local subject=""

    while IFS= read -r subject; do
        [[ -z "$subject" ]] && continue

        case "$subject" in
            feat:\ *)
                added+=("${subject#feat: }")
                ;;
            fix:\ *)
                fixed+=("${subject#fix: }")
                ;;
            *:\ *)
                changed+=("${subject#*: }")
                ;;
            *)
                changed+=("$subject")
                ;;
        esac
    done < <(git -C "$RELEASE_REPO_ROOT" log "$range" --no-merges --reverse --format='%s')

    if (( ${#added[@]} == 0 && ${#fixed[@]} == 0 && ${#changed[@]} == 0 )); then
        release_die "no commits found for release range: $range"
    fi

    print -- "## [$version] - $release_date"
    print

    if [[ -z "$previous_tag" ]]; then
        print -- "_Initial release from current repository history._"
        print
    fi

    release_emit_bullets "Added" "${added[@]}"
    release_emit_bullets "Fixed" "${fixed[@]}"
    release_emit_bullets "Changed" "${changed[@]}"
}

function release_insert_changelog_section() {
    local version="$1"
    local section="$2"

    [[ -f "$RELEASE_CHANGELOG_FILE" ]] || release_die "missing changelog at $RELEASE_CHANGELOG_FILE"

    if grep -Fq "## [$version] - " "$RELEASE_CHANGELOG_FILE"; then
        release_die "CHANGELOG.md already contains an entry for $version"
    fi

    if ! grep -Fq "$RELEASE_CHANGELOG_MARKER" "$RELEASE_CHANGELOG_FILE"; then
        release_die "CHANGELOG.md is missing release marker: $RELEASE_CHANGELOG_MARKER"
    fi

    local temp_file section_file
    temp_file="$(mktemp "${TMPDIR:-/tmp}/rollkeep-changelog.XXXXXX")"
    section_file="$(mktemp "${TMPDIR:-/tmp}/rollkeep-changelog-section.XXXXXX")"
    print -- "$section" > "$section_file"

    awk -v marker="$RELEASE_CHANGELOG_MARKER" -v section_file="$section_file" '
        $0 == marker {
            while ((getline line < section_file) > 0) {
                print line
            }
            close(section_file)
            print ""
            print marker
            next
        }
        { print }
    ' "$RELEASE_CHANGELOG_FILE" > "$temp_file"

    rm -f "$section_file"
    mv "$temp_file" "$RELEASE_CHANGELOG_FILE"
}

function release_write_notes_file() {
    local version="$1"
    local output_path="$2"
    local tag
    tag="$(release_release_tag "$version")"

    {
        print -- "# Release ${tag}"
        print
        awk -v version="$version" '
            BEGIN {
                capture = 0
                found = 0
            }
            index($0, "## [" version "] - ") == 1 {
                capture = 1
                found = 1
                next
            }
            capture && /^## \[/ {
                exit
            }
            capture {
                print
            }
            END {
                if (!found) {
                    exit 1
                }
            }
        ' "$RELEASE_CHANGELOG_FILE"
    } > "$output_path" || release_die "unable to extract release notes for $version from CHANGELOG.md"
}
