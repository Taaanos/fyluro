#!/bin/zsh

set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/release-common.sh"

function usage() {
    cat <<'EOF'
Run the full local release flow in one command.

Usage:
  scripts/release-cut.sh (--bump major|minor|patch | --version <version>) [--no-publish] [--dry-run] [--commit-message <message>]

Examples:
  scripts/release-cut.sh --bump patch
  scripts/release-cut.sh --bump minor --no-publish
  scripts/release-cut.sh --version 0.2.0 --commit-message "chore: release v0.2.0 with ingest fixes"
  scripts/release-cut.sh --bump patch --dry-run
EOF
}

dry_run=0
no_publish=0
bump=""
target_version=""
commit_message=""

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
        --commit-message)
            shift
            [[ $# -gt 0 ]] || release_die "--commit-message requires a value"
            commit_message="$1"
            ;;
        --no-publish)
            no_publish=1
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

if (( dry_run )); then
    if [[ -n "$target_version" ]]; then
        "$RELEASE_SCRIPT_DIR/release-prepare.sh" --version "$target_version" --dry-run
    else
        "$RELEASE_SCRIPT_DIR/release-prepare.sh" --bump "$bump" --dry-run
    fi

    print -- "Dry run complete. No release metadata changed, no commit created, no publish performed."
    exit 0
fi

release_require_command git
release_require_clean_git

if [[ -n "$target_version" ]]; then
    "$RELEASE_SCRIPT_DIR/release-prepare.sh" --version "$target_version"
else
    "$RELEASE_SCRIPT_DIR/release-prepare.sh" --bump "$bump"
fi

target_version="$(release_read_version)"
target_tag="$(release_release_tag "$target_version")"

if [[ -z "$commit_message" ]]; then
    commit_message="chore: release ${target_tag}"
fi

release_note "Committing release metadata..."
git -C "$RELEASE_REPO_ROOT" add VERSION CHANGELOG.md
git -C "$RELEASE_REPO_ROOT" commit -m "$commit_message"

if (( no_publish )); then
    print -- "Release ${target_tag} prepared and committed locally."
    print -- "Publish when ready:"
    print -- "  scripts/release-publish.sh --version ${target_version}"
    exit 0
fi

release_note "Publishing release..."
"$RELEASE_SCRIPT_DIR/release-publish.sh" --version "$target_version"
