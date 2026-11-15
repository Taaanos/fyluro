#!/bin/zsh

set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/release-common.sh"

function usage() {
    cat <<'EOF'
Regression check for the fixed ISOBMFFBoxWalker integer-overflow crash (RT-P0-12 / E2E-040).
Confirms a crafted box header no longer crashes the real rollkeep binary -- it's now handled
gracefully as an ordinary candidate with no resolvable embedded metadata, ingested normally.

Usage:
  scripts/e2e-boxwalker-overflow-crash-test.sh
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
release_ensure_debug_rollkeep_binary "box-walker overflow-crash E2E"

python3 "$RELEASE_SCRIPT_DIR/e2e-boxwalker-overflow-crash.py" \
    --binary "$binary" \
    --repo-root "$RELEASE_REPO_ROOT"
