#!/bin/zsh

set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/release-common.sh"

function usage() {
    cat <<'EOF'
Run CLI signal cancellation E2E checks (SIGINT, SIGTERM, SIGHUP, and double-signal force exit).

Usage:
  scripts/e2e-cli-signal-cancellation-test.sh
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
fi

release_require_command python3
release_require_command swift
release_enable_swift_local_caches

binary="$RELEASE_REPO_ROOT/.build/debug/rollkeep"
release_ensure_debug_rollkeep_binary "CLI signal cancellation E2E"

python3 "$RELEASE_SCRIPT_DIR/e2e-cli-signal-cancellation.py" \
    --binary "$binary" \
    --repo-root "$RELEASE_REPO_ROOT"
