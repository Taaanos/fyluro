#!/bin/zsh

set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/release-common.sh"

function usage() {
    cat <<'EOF'
Prepare a local RollKeep release by validating, packaging, and updating release metadata.

Usage:
  scripts/release-prepare.sh (--bump major|minor|patch | --version <version>) [--dry-run]

Examples:
  scripts/release-prepare.sh --bump minor
  scripts/release-prepare.sh --version 0.2.0
  scripts/release-prepare.sh --bump patch --dry-run
EOF
}

dry_run=0
bump=""
target_version=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --bump)
            shift
            [[ $# -gt 0 ]] || release_die "--bump requires a value"
            bump="$1"
            ;;
        --version)
            shift
            [[ $# -gt 0 ]] || release_die "--version requires a value"
            target_version="$1"
            ;;
        --dry-run)
            dry_run=1
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            release_die "unknown argument: $1"
            ;;
    esac
    shift
done

if [[ -n "$bump" && -n "$target_version" ]]; then
    release_die "use either --bump or --version, not both"
fi

if [[ -z "$bump" && -z "$target_version" ]]; then
    release_die "either --bump or --version is required"
fi

release_require_command git
release_require_command swift
release_enable_swift_local_caches

release_require_clean_git

current_version="$(release_read_version)"

if [[ -n "$target_version" ]]; then
    release_validate_version "$target_version"
else
    target_version="$(release_bump_version "$current_version" "$bump")"
fi

[[ "$target_version" != "$current_version" ]] || release_die "target version matches VERSION; choose a different version"

target_tag="$(release_release_tag "$target_version")"

if git -C "$RELEASE_REPO_ROOT" rev-parse -q --verify "refs/tags/${target_tag}" >/dev/null 2>&1; then
    release_die "local git tag already exists: $target_tag"
fi

previous_tag="$(release_latest_tag)"
log_range="$(release_log_range "$previous_tag")"
changelog_section="$(release_render_changelog_section "$target_version" "$previous_tag" "$log_range")"

release_note "Preparing ${target_tag} from ${previous_tag:-repository history}."
release_note "Running swift test..."
swift test

release_note "Running local smoke ingest checks..."
"$RELEASE_SCRIPT_DIR/release-smoke-test.sh"

release_note "Running full e2e test suite..."
"$RELEASE_SCRIPT_DIR/run-e2e-tests.sh"

release_note "Building macOS release bundle..."
"$RELEASE_SCRIPT_DIR/package-macos-app.sh" --version "$target_version"

release_note "Verifying packaged app bundle..."
"$RELEASE_SCRIPT_DIR/release-app-smoke-test.sh" --version "$target_version"

if (( dry_run )); then
    print -- "Dry run complete for ${target_tag}."
    print -- "Current version: ${current_version}"
    print -- "Next version: ${target_version}"
    print -- "Previous tag: ${previous_tag:-none}"
    print -- "Artifacts:"
    print -- "  $(release_zip_path "$target_version")"
    print -- "  $(release_checksum_path "$target_version")"
    print
    print -- "Generated changelog section:"
    print
    print -- "$changelog_section"
    exit 0
fi

release_write_version "$target_version"
release_insert_changelog_section "$target_version" "$changelog_section"

print -- "Prepared ${target_tag}."
print -- "Updated:"
print -- "  $RELEASE_VERSION_FILE"
print -- "  $RELEASE_CHANGELOG_FILE"
print -- "Built:"
print -- "  $(release_zip_path "$target_version")"
print -- "  $(release_checksum_path "$target_version")"
print
print -- "Next steps:"
print -- "  git add VERSION CHANGELOG.md"
print -- "  git commit -m \"chore: release ${target_tag}\""
print -- "  scripts/release-publish.sh --version ${target_version}"
