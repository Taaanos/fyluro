#!/bin/zsh

set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/release-common.sh"

function usage() {
    cat <<'EOF'
Run overlap preflight E2E checks for:
  - E2E-013 reject source == destination
  - E2E-014 reject destination nested in source

Usage:
  scripts/e2e-overlap-preflight-test.sh
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
release_ensure_debug_rollkeep_binary "overlap preflight E2E"

python3 "$RELEASE_SCRIPT_DIR/e2e-overlap-preflight.py" \
    --binary "$binary" \
    --repo-root "$RELEASE_REPO_ROOT"
