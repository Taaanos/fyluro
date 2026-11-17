#!/bin/zsh

set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/release-common.sh"

function usage() {
    cat <<'EOF'
Write the Homebrew cask for a RollKeep release into a tap checkout (Taaanos/homebrew-tap).

Usage:
  scripts/make-cask.sh --version <version> --tap <dir>

Example:
  scripts/make-cask.sh --version 0.6.1 --tap ../homebrew-tap
EOF
}

version=""
tap=""

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

checksum_path="$(release_checksum_path "$version")"
[[ -f "$checksum_path" ]] || release_die "missing checksum file: $checksum_path (run scripts/package-macos-app.sh --version $version first)"

sum="$(cut -d' ' -f1 "$checksum_path")"
[[ ${#sum} -eq 64 ]] || release_die "invalid sha256 in $checksum_path"

mkdir -p "$tap/Casks"

cat > "$tap/Casks/rollkeep.rb" <<CASK
cask "rollkeep" do
  version "$version"
  sha256 "$sum"

  url "https://github.com/Taaanos/rollkeep/releases/download/v#{version}/RollKeep-#{version}-macos-arm64.zip"
  name "RollKeep"
  desc "Verified media offload app for camera cards"
  homepage "https://github.com/Taaanos/rollkeep"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on arch: :arm64
  depends_on macos: ">= :ventura"

  app "RollKeep.app"

  # The build has no Developer ID, so Gatekeeper blocks it while the quarantine mark is on it.
  # Homebrew sets the mark on each download; this removes it from the app only.
  postflight do
    system_command "/usr/bin/xattr",
                   args: ["-dr", "com.apple.quarantine", "#{appdir}/RollKeep.app"]
  end

  zap trash: [
    "~/Library/Containers/com.thanosam.rollkeep",
    "~/Library/Caches/com.thanosam.rollkeep",
    "~/Library/Preferences/com.thanosam.rollkeep.plist",
    "~/Library/Saved Application State/com.thanosam.rollkeep.savedState",
  ]
end
CASK

print -- "Wrote $tap/Casks/rollkeep.rb"
