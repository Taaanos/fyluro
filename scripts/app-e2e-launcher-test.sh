#!/bin/zsh

set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/release-common.sh"

function usage() {
    cat <<'EOF'
Run launcher app-surface end-to-end tests against fixture sources.

Usage:
  scripts/app-e2e-launcher-test.sh
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
fi

release_require_command swift
release_enable_swift_local_caches

release_note "Building debug rollkeep binary for launcher app E2E..."
swift build --disable-sandbox --product rollkeep >/dev/null

binary="$RELEASE_REPO_ROOT/.build/debug/rollkeep"
[[ -x "$binary" ]] || release_die "expected rollkeep binary not found at $binary"

release_note "Running launcher app-surface E2E suite..."
ROLLKEEP_RUN_APP_E2E=1 swift test --disable-sandbox --parallel --num-workers 1 --filter LauncherAppE2ETests

release_note "Launcher app-surface E2E suite passed."
