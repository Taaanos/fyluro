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

release_ensure_source_card_fixtures

typeset -a e2e_scripts
e2e_scripts=("$RELEASE_REPO_ROOT"/scripts/*e2e*-test.sh(N))

if (( ${#e2e_scripts[@]} == 0 )); then
    release_die "no e2e test scripts found in $RELEASE_REPO_ROOT/scripts"
fi

release_require_command swift
release_note "Building debug binaries for E2E suite..."
(
    release_enable_swift_local_caches
    swift build --disable-sandbox --product fyluro >/dev/null
    swift build --disable-sandbox --product fyluro-launcher >/dev/null
)
export FYLURO_SKIP_BUILD=1

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
