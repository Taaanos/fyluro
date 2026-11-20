#!/bin/zsh

set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/release-common.sh"

function usage() {
    cat <<'EOF'
Run launcher app-surface end-to-end tests against fixture sources.

Usage:
  scripts/app-e2e-launcher-test.sh

Environment overrides:
  FYLURO_APP_E2E_WORKERS=<n>   (default: 4)
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
fi

release_require_command swift
release_enable_swift_local_caches

if [[ "${FYLURO_SKIP_BUILD:-0}" != "1" ]]; then
    release_note "Building debug launcher for app E2E..."
    # The launcher now runs ingest in-process via FyluroEngine; no CLI binary is
    # required for these tests.
    swift build --disable-sandbox --product fyluro-launcher >/dev/null
fi

workers="${FYLURO_APP_E2E_WORKERS:-4}"

release_note "Running launcher app-surface E2E suite..."
FYLURO_RUN_APP_E2E=1 swift test --disable-sandbox --parallel --num-workers "$workers" --filter LauncherAppE2ETests

release_note "Launcher app-surface E2E suite passed."
