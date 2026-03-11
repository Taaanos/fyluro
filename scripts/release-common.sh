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
