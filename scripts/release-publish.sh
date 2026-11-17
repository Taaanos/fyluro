#!/bin/zsh

set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/release-common.sh"

function usage() {
    cat <<'EOF'
Publish a prepared RollKeep release with git and GitHub CLI.

Usage:
  scripts/release-publish.sh [--version <version>] [--tap <dir>] [--dry-run]

Examples:
  scripts/release-publish.sh
  scripts/release-publish.sh --version 0.2.0 --tap ../homebrew-tap
  scripts/release-publish.sh --dry-run
EOF
}

dry_run=0
target_version=""
tap=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version)
            shift
            [[ $# -gt 0 ]] || release_die "--version requires a value"
            target_version="$1"
            ;;
        --tap)
            shift
            [[ $# -gt 0 ]] || release_die "--tap requires a value"
            tap="$1"
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

release_require_command git
release_require_command gh

release_require_clean_git

tap_abs=""
if [[ -n "$tap" ]]; then
    [[ -d "$tap/.git" ]] || release_die "not a git checkout: $tap"
    tap_abs="$(cd "$tap" && pwd)"
    [[ -z "$(git -C "$tap_abs" status --porcelain --untracked-files=no)" ]] || release_die "the tap working tree is not clean: $tap_abs"
    git -C "$tap_abs" rev-parse --abbrev-ref '@{upstream}' >/dev/null 2>&1 || release_die "the tap branch has no upstream: push it once with git push -u origin HEAD"
fi

if [[ -z "$target_version" ]]; then
    target_version="$(release_read_version)"
else
    release_validate_version "$target_version"
fi

target_tag="$(release_release_tag "$target_version")"
current_branch="$(release_current_branch)"

[[ -n "$current_branch" ]] || release_die "release publish requires a checked-out branch"

release_verify_assets "$target_version"

head_commit="$(git -C "$RELEASE_REPO_ROOT" rev-parse HEAD)"
tag_commit="$(git -C "$RELEASE_REPO_ROOT" rev-parse -q --verify "refs/tags/${target_tag}^{commit}" 2>/dev/null || true)"

if [[ -n "$tag_commit" && "$tag_commit" != "$head_commit" ]]; then
    release_die "local tag ${target_tag} exists but does not point at HEAD"
fi

notes_file="$(mktemp "${TMPDIR:-/tmp}/rollkeep-release-notes.XXXXXX.md")"

function cleanup() {
    rm -f "$notes_file"
}

trap cleanup EXIT

release_write_notes_file "$target_version" "$notes_file"

if (( dry_run )); then
    print -- "Dry run complete for ${target_tag}."
    print -- "Branch: ${current_branch}"
    print -- "Assets:"
    print -- "  $(release_zip_path "$target_version")"
    print -- "  $(release_checksum_path "$target_version")"
    print -- "Release notes: $notes_file"
    print
    print -- "Would run:"
    if [[ -z "$tag_commit" ]]; then
        print -- "  git tag -a ${target_tag} -m \"Release ${target_tag}\""
    else
        print -- "  # local tag ${target_tag} already points at HEAD"
    fi
    print -- "  git push origin ${current_branch}"
    print -- "  git push origin ${target_tag}"
    print -- "  gh release create|edit ${target_tag} ..."
    if [[ -n "$tap_abs" ]]; then
        print -- "  scripts/make-cask.sh --version ${target_version} --tap ${tap_abs}"
        print -- "  scripts/make-formula.sh --version ${target_version} --tap ${tap_abs}"
        print -- "  # prompt to commit and push ${tap_abs}"
    fi
    exit 0
fi

gh auth status >/dev/null 2>&1 || release_die "gh is not authenticated; run gh auth login first"

if [[ -z "$tag_commit" ]]; then
    release_note "Creating annotated tag ${target_tag}..."
    git -C "$RELEASE_REPO_ROOT" tag -a "$target_tag" -m "Release ${target_tag}"
fi

release_note "Pushing ${current_branch} to origin..."
git -C "$RELEASE_REPO_ROOT" push origin "$current_branch"

release_note "Pushing ${target_tag} to origin..."
git -C "$RELEASE_REPO_ROOT" push origin "$target_tag"

if gh release view "$target_tag" >/dev/null 2>&1; then
    release_note "Updating GitHub release ${target_tag}..."
    gh release edit "$target_tag" --title "$target_tag" --notes-file "$notes_file"
    gh release upload "$target_tag" "$(release_zip_path "$target_version")" "$(release_checksum_path "$target_version")" --clobber
else
    release_note "Creating GitHub release ${target_tag}..."
    gh release create "$target_tag" "$(release_zip_path "$target_version")" "$(release_checksum_path "$target_version")" --title "$target_tag" --notes-file "$notes_file" --verify-tag
fi

print -- "Published ${target_tag}."
print -- "GitHub release assets:"
print -- "  $(release_zip_path "$target_version")"
print -- "  $(release_checksum_path "$target_version")"

if [[ -n "$tap_abs" ]]; then
    release_note "Updating Homebrew tap at ${tap_abs}..."
    "$RELEASE_SCRIPT_DIR/make-cask.sh" --version "$target_version" --tap "$tap_abs"
    "$RELEASE_SCRIPT_DIR/make-formula.sh" --version "$target_version" --tap "$tap_abs"
    print
    git -C "$tap_abs" status --short
    git -C "$tap_abs" diff
    printf 'Commit and push the tap (%s) for rollkeep %s? [y/N] ' "$tap_abs" "$target_version"
    read -r answer
    if [[ "$answer" == "y" || "$answer" == "Y" ]]; then
        git -C "$tap_abs" add Casks/rollkeep.rb Formula/rollkeep.rb
        git -C "$tap_abs" commit -q -m "rollkeep ${target_version}"
        git -C "$tap_abs" push
        print -- "Tap pushed."
    else
        release_die "tap not pushed; commit and push $tap_abs manually"
    fi
fi
