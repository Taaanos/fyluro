#!/bin/zsh

set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/release-common.sh"

function usage() {
    cat <<'EOF'
Run local ingest smoke checks used by the release flow.

Usage:
  scripts/release-smoke-test.sh
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
fi

release_require_command swift
release_require_command jq
release_require_command shasum
release_enable_swift_local_caches

binary="$RELEASE_REPO_ROOT/.build/debug/rollkeep"
release_ensure_debug_rollkeep_binary "smoke checks"

temp_root="$(mktemp -d "${TMPDIR:-/tmp}/rollkeep-release-smoke.XXXXXX")"

function cleanup() {
    rm -rf "$temp_root"
}

trap cleanup EXIT

release_smoke_run_ingest_fixture_suite "$binary" "$temp_root"

release_note "Local release smoke checks passed."
