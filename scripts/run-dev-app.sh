#!/bin/zsh

set -euo pipefail

function usage() {
    cat <<'EOF'
Build a debug RollKeep.app bundle and launch it for manual testing.

Usage:
  scripts/run-dev-app.sh

Builds the rollkeep-launcher debug binary and wraps it in a minimal
RollKeep-dev.app bundle under dist/, then opens it. This is dev-only
(unsigned, no icon, no CLI, no zip) — for the real release bundle see
scripts/package-macos-app.sh.

A bare debug executable launched directly from the terminal doesn't
get normal window-server activation from macOS, so keyboard input
stays with the launching terminal instead of the app window. Wrapping
it in a proper .app bundle (with an Info.plist) and opening it via
`open` fixes that.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
fi

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
cd "$repo_root"

launcher_executable="rollkeep-launcher"
bundle_identifier="com.thanosam.rollkeep.dev"
app_bundle="$repo_root/dist/RollKeep-dev.app"
contents_dir="$app_bundle/Contents"
macos_dir="$contents_dir/MacOS"
plist_path="$contents_dir/Info.plist"
launcher_binary_in_bundle="$macos_dir/$launcher_executable"

# `open` on an already-running app just re-activates the existing process
# instead of launching the freshly-built one, so a previous run's window can
# stick around showing stale code. Quit it first.
if pgrep -f "$launcher_binary_in_bundle" >/dev/null 2>&1; then
    echo "Quitting existing RollKeep (Dev) instance..." >&2
    pkill -f "$launcher_binary_in_bundle" || true
    sleep 0.5
fi

echo "Building debug launcher..." >&2
swift build --product "$launcher_executable" >/dev/null

bin_dir="$(swift build --show-bin-path)"
launcher_binary="$bin_dir/$launcher_executable"
if [[ ! -x "$launcher_binary" ]]; then
    echo "error: launcher binary not found at $launcher_binary" >&2
    exit 1
fi

resources_dir="$contents_dir/Resources"

rm -rf "$app_bundle"
mkdir -p "$macos_dir" "$resources_dir"
cp "$launcher_binary" "$macos_dir/$launcher_executable"
chmod 755 "$macos_dir/$launcher_executable"

# SwiftPM auto-copies RollKeepCore's generated resource bundle (camera model
# catalogs) next to the built binary under .build/, but this script then
# copies just the binary out to dist/RollKeep-dev.app, leaving the bundle
# behind -- so it needs the same manual copy scripts/package-macos-app.sh
# does. See that script's comment for why both MacOS/ and Resources/.
resource_bundle_name="rollkeep_RollKeepCore.bundle"
resource_bundle="$bin_dir/$resource_bundle_name"

if [[ -d "$resource_bundle" ]]; then
    cp -R "$resource_bundle" "$macos_dir/$resource_bundle_name"
    cp -R "$resource_bundle" "$resources_dir/$resource_bundle_name"
else
    echo "warning: resource bundle not found at $resource_bundle; camera labels may fall back to raw model codes" >&2
fi

cat > "$plist_path" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleDisplayName</key>
    <string>RollKeep (Dev)</string>
    <key>CFBundleExecutable</key>
    <string>${launcher_executable}</string>
    <key>CFBundleIdentifier</key>
    <string>${bundle_identifier}</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>RollKeep Dev</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.0.0-dev</string>
    <key>CFBundleVersion</key>
    <string>0.0.0-dev</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
EOF

echo "Launching $app_bundle ..." >&2
open "$app_bundle"
