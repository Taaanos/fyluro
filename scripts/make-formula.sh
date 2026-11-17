#!/bin/zsh

set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/release-common.sh"

function usage() {
    cat <<'EOF'
Write the Homebrew formula for the rollkeep CLI into a tap checkout (Taaanos/homebrew-tap).

Usage:
  scripts/make-formula.sh --version <version> --tap <dir> [--sha256 <hex>]

Examples:
  scripts/make-formula.sh --version 0.6.1 --tap ../homebrew-tap
  scripts/make-formula.sh --version 0.6.1 --tap ../homebrew-tap --sha256 <64-char-hex>
EOF
}

version=""
tap=""
sum=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version)
            shift
            [[ $# -gt 0 ]] || release_die "--version requires a value"
            version="$1"
            ;;
        --tap)
            shift
            [[ $# -gt 0 ]] || release_die "--tap requires a value"
            tap="$1"
            ;;
        --sha256)
            shift
            [[ $# -gt 0 ]] || release_die "--sha256 requires a value"
            sum="$1"
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            release_die "unknown argument: $1"
            ;;
    esac
    shift
done

[[ -n "$version" ]] || release_die "--version is required"
[[ -n "$tap" ]] || release_die "--tap is required"

release_validate_version "$version"
[[ -d "$tap/.git" ]] || release_die "not a git checkout: $tap"

tag="$(release_release_tag "$version")"
tarball_url="https://github.com/Taaanos/rollkeep/archive/refs/tags/${tag}.tar.gz"

if [[ -z "$sum" ]]; then
    release_require_command curl
    tarball_tmp="$(mktemp "${TMPDIR:-/tmp}/rollkeep-src.XXXXXX.tar.gz")"
    trap 'rm -f "$tarball_tmp"' EXIT
    release_note "Fetching source tarball ${tarball_url}..."
    curl -fsSL "$tarball_url" -o "$tarball_tmp" || release_die "failed to download $tarball_url (is tag $tag pushed to GitHub?)"
    sum="$(/usr/bin/shasum -a 256 "$tarball_tmp" | cut -d' ' -f1)"
fi

[[ ${#sum} -eq 64 ]] || release_die "invalid sha256: $sum"

mkdir -p "$tap/Formula"

cat > "$tap/Formula/rollkeep.rb" <<FORMULA
class Rollkeep < Formula
  desc "Verified media offload CLI for camera cards"
  homepage "https://github.com/Taaanos/rollkeep"
  url "https://github.com/Taaanos/rollkeep/archive/refs/tags/v${version}.tar.gz"
  sha256 "$sum"
  license "GPL-3.0-or-later"

  depends_on arch: :arm64
  depends_on macos: :ventura

  def install
    system "swift", "build", "--disable-sandbox", "-c", "release", "--product", "rollkeep"
    bin.install ".build/release/rollkeep"
  end

  test do
    assert_match "Safely ingest media", shell_output("#{bin}/rollkeep --help")
  end
end
FORMULA

print -- "Wrote $tap/Formula/rollkeep.rb"
