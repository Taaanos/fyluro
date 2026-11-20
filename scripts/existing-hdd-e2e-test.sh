#!/bin/zsh

set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/release-common.sh"

function usage() {
    cat <<'EOF'
Run existing-HDD ingest e2e checks against the bundled SD card fixtures.

Usage:
  scripts/existing-hdd-e2e-test.sh

Environment overrides:
  FYLURO_E2E_FIXTURE_PROFILE=fast|full   (default: fast)
  FYLURO_E2E_WORKERS=<n>                 (default: 4)
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
release_ensure_debug_fyluro_binary "existing-HDD e2e checks"

fixture_profile="${FYLURO_E2E_FIXTURE_PROFILE:-fast}"
workers="${FYLURO_E2E_WORKERS:-4}"

python3 "$RELEASE_SCRIPT_DIR/existing-hdd-e2e.py" \
    --binary "$binary" \
    --repo-root "$RELEASE_REPO_ROOT" \
    --fixture-profile "$fixture_profile" \
    --workers "$workers"
