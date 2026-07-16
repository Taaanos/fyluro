#!/bin/zsh

set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/release-common.sh"

function usage() {
    cat <<'EOF'
Reproduce the ISOBMFFBoxWalker integer-overflow crash at the CLI level (RT-P0-12 / E2E-040).
Confirms a crafted box header crashes the real rollkeep binary via a signal (not a graceful
per-file error), and that the source card is left untouched despite the crash.

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

release_note "Building debug rollkeep binary for box-walker overflow-crash E2E..."
swift build --disable-sandbox --product rollkeep >/dev/null

[[ -x "$binary" ]] || release_die "expected rollkeep binary not found at $binary"

python3 "$RELEASE_SCRIPT_DIR/e2e-boxwalker-overflow-crash.py" \
    --binary "$binary" \
    --repo-root "$RELEASE_REPO_ROOT"
