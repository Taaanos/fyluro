#!/bin/zsh

set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/release-common.sh"

function usage() {
    cat <<'EOF'
Run existing-HDD ingest e2e checks against the bundled SD card fixtures.

Usage:
  scripts/existing-hdd-e2e-test.sh
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

if [[ ! -x "$binary" ]]; then
    release_note "Building debug rollkeep binary for existing-HDD e2e checks..."
    swift build --product rollkeep >/dev/null
fi

[[ -x "$binary" ]] || release_die "expected rollkeep binary not found at $binary"

python3 "$RELEASE_SCRIPT_DIR/existing-hdd-e2e.py" \
    --binary "$binary" \
    --repo-root "$RELEASE_REPO_ROOT"
