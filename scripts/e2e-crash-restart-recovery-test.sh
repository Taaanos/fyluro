#!/bin/zsh

set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/release-common.sh"

function usage() {
    cat <<'EOF'
Run crash/restart recovery E2E checks for retained staging + deterministic rerun behavior (E2E-022).

Usage:
  scripts/e2e-crash-restart-recovery-test.sh
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

release_note "Building debug rollkeep binary for crash/restart E2E..."
swift build --disable-sandbox --product rollkeep >/dev/null

[[ -x "$binary" ]] || release_die "expected rollkeep binary not found at $binary"

python3 "$RELEASE_SCRIPT_DIR/e2e-crash-restart-recovery.py" \
    --binary "$binary" \
    --repo-root "$RELEASE_REPO_ROOT"
