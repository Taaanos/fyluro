#!/bin/zsh

set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/release-common.sh"

function usage() {
    cat <<'EOF'
Regression check for the fixed unbounded embedded-metadata-string issue (RT-P1-10 / E2E-041).
Confirms an oversized "Model:" field in a crafted video no longer (a) blocks ingestion of the
entire card, or (b) produces an absurd-but-legal camera folder -- both variants now fall back
to unknown-camera safely, via the real fyluro binary with --pdf enabled.

Usage:
  scripts/e2e-metadata-length-bomb-test.sh
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
fi

release_require_command python3
release_require_command swift
release_enable_swift_local_caches

binary="$RELEASE_REPO_ROOT/.build/debug/fyluro"
release_ensure_debug_fyluro_binary "metadata length-bomb E2E"

python3 "$RELEASE_SCRIPT_DIR/e2e-metadata-length-bomb.py" \
    --binary "$binary" \
    --repo-root "$RELEASE_REPO_ROOT"
