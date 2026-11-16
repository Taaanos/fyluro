#!/bin/zsh

set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/release-common.sh"

function usage() {
    cat <<'EOF'
Run all e2e test scripts in scripts/ sequentially.

Usage:
  scripts/run-e2e-tests.sh

Each *-e2e-test.sh / *-e2e-launcher-test.sh script is run in turn; a
summary of pass/fail results is printed at the end. Exits non-zero if
any test failed.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
fi

if [[ ! -d "$RELEASE_REPO_ROOT/Tests/TestingDirs/SD_CARD1" || ! -d "$RELEASE_REPO_ROOT/Tests/TestingDirs/SD_CARD2" ]]; then
    release_note "Source-card fixtures not found; generating synthetic fixtures..."
    python3 "$RELEASE_REPO_ROOT/scripts/build-e2e-fixtures.py" --synthetic --force
fi

release_note "Checking source-card fixtures..."
if ! python3 "$RELEASE_REPO_ROOT/scripts/build-e2e-fixtures.py" --check; then
    release_die "fixture check failed; run python3 scripts/build-e2e-fixtures.py --synthetic --force (see Tests/e2e-ingest-matrix.md)"
fi

typeset -a e2e_scripts
e2e_scripts=("$RELEASE_REPO_ROOT"/scripts/*e2e*-test.sh(N))

if (( ${#e2e_scripts[@]} == 0 )); then
    release_die "no e2e test scripts found in $RELEASE_REPO_ROOT/scripts"
fi

release_require_command swift
release_note "Building debug binaries for E2E suite..."
(
    release_enable_swift_local_caches
    swift build --disable-sandbox --product rollkeep >/dev/null
    swift build --disable-sandbox --product rollkeep-launcher >/dev/null
)
export ROLLKEEP_SKIP_BUILD=1

typeset -a passed failed
passed=()
failed=()

for script in $e2e_scripts; do
    name="$(basename "$script")"
    release_note "Running $name..."
    if "$script"; then
        passed+=("$name")
    else
        failed+=("$name")
    fi
done

echo
release_note "E2E test summary:"
for name in $passed; do
    echo "  PASS  $name"
done
for name in $failed; do
    echo "  FAIL  $name"
done

if (( ${#failed[@]} > 0 )); then
    exit 1
fi
