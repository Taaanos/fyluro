#!/bin/zsh

set -euo pipefail

function usage() {
    cat <<'EOF'
Build an Apple Silicon RollKeep.app bundle and zip it for GitHub Releases.

Usage:
  scripts/package-macos-app.sh --version <version>

Example:
  scripts/package-macos-app.sh --version 0.1.0
EOF
}

version=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version)
            shift
            if [[ $# -eq 0 ]]; then
                echo "error: --version requires a value" >&2
                usage >&2
                exit 1
            fi
            version="$1"
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "error: unknown argument: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
    shift
done

if [[ -z "$version" ]]; then
    echo "error: --version is required" >&2
    usage >&2
    exit 1
fi

if [[ "$version" == *[[:space:]]* ]]; then
    echo "error: version must not contain whitespace" >&2
    exit 1
fi

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"

app_name="RollKeep"
bundle_name="${app_name}.app"
arch="arm64"
launcher_executable="rollkeep-launcher"
cli_executable="rollkeep"
bundle_identifier="com.thanosam.rollkeep"
minimum_macos="13.0"
icon_source="$repo_root/assets/macos/AppIcon.png"
icon_name="AppIcon"

dist_dir="$repo_root/dist"
app_bundle="$dist_dir/$bundle_name"
contents_dir="$app_bundle/Contents"
macos_dir="$contents_dir/MacOS"
resources_dir="$contents_dir/Resources"
plist_path="$contents_dir/Info.plist"
zip_name="${app_name}-${version}-macos-${arch}.zip"
zip_path="$dist_dir/$zip_name"
checksum_name="${zip_name}.sha256"
checksum_path="$dist_dir/$checksum_name"
icon_temp_root=""
iconset_dir=""

cd "$repo_root"

if [[ ! -f "$icon_source" ]]; then
    echo "error: expected app icon source not found at $icon_source" >&2
    exit 1
fi

function cleanup() {
    if [[ -n "$icon_temp_root" && -d "$icon_temp_root" ]]; then
        rm -rf "$icon_temp_root"
    fi
    if [[ -n "$iconset_dir" && -d "$iconset_dir" ]]; then
        rm -rf "$iconset_dir"
    fi
}

trap cleanup EXIT

function render_icon() {
    local size="$1"
    local output_path="$2"
    /usr/bin/sips -z "$size" "$size" "$icon_source" --out "$output_path" >/dev/null
}

echo "Building release binaries for ${arch}..."
# SwiftPM accepts a single --product per invocation. Build both explicitly
# so the bundled CLI and launcher are always from the same source revision.
swift build -c release --arch "$arch" --product "$cli_executable"
swift build -c release --arch "$arch" --product "$launcher_executable"

bin_dir="$(swift build --show-bin-path -c release --arch "$arch")"
launcher_binary="$bin_dir/$launcher_executable"
cli_binary="$bin_dir/$cli_executable"

if [[ ! -x "$launcher_binary" ]]; then
    echo "error: expected launcher binary not found at $launcher_binary" >&2
    exit 1
fi

if [[ ! -x "$cli_binary" ]]; then
    echo "error: expected CLI binary not found at $cli_binary" >&2
    exit 1
fi

rm -rf "$app_bundle"
rm -f "$zip_path" "$checksum_path"
mkdir -p "$macos_dir" "$resources_dir"

cp "$launcher_binary" "$macos_dir/$launcher_executable"
cp "$cli_binary" "$macos_dir/$cli_executable"
chmod 755 "$macos_dir/$launcher_executable" "$macos_dir/$cli_executable"

# SwiftPM generates one resource bundle for RollKeepCore's bundled data
# (e.g. camera model catalogs), named <package>_<target>.bundle, built
# alongside the two binaries above -- it is not copied automatically since
# this script assembles Contents/ by hand rather than via Xcode. Copied to
# both MacOS/ and Resources/: `rollkeep-launcher`'s Bundle.main resolves to
# the .app (-> Resources/), while `rollkeep` run directly out of MacOS/ may
# resolve Bundle.module relative to the executable's own directory instead.
resource_bundle_name="rollkeep_RollKeepCore.bundle"
resource_bundle="$bin_dir/$resource_bundle_name"

if [[ ! -d "$resource_bundle" ]]; then
    echo "error: expected SwiftPM resource bundle not found at $resource_bundle" >&2
    exit 1
fi

cp -R "$resource_bundle" "$macos_dir/$resource_bundle_name"
cp -R "$resource_bundle" "$resources_dir/$resource_bundle_name"

icon_temp_root="$(mktemp -d "${TMPDIR:-/tmp}/rollkeep-app-icon.XXXXXX")"
iconset_dir="$icon_temp_root/${icon_name}.iconset"
mkdir -p "$iconset_dir"
render_icon 16 "$iconset_dir/icon_16x16.png"
render_icon 32 "$iconset_dir/icon_16x16@2x.png"
render_icon 32 "$iconset_dir/icon_32x32.png"
render_icon 64 "$iconset_dir/icon_32x32@2x.png"
render_icon 128 "$iconset_dir/icon_128x128.png"
render_icon 256 "$iconset_dir/icon_128x128@2x.png"
render_icon 256 "$iconset_dir/icon_256x256.png"
render_icon 512 "$iconset_dir/icon_256x256@2x.png"
render_icon 512 "$iconset_dir/icon_512x512.png"
cp "$icon_source" "$iconset_dir/icon_512x512@2x.png"

/usr/bin/iconutil -c icns "$iconset_dir" -o "$resources_dir/${icon_name}.icns"

cat > "$plist_path" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleDisplayName</key>
    <string>${app_name}</string>
    <key>CFBundleExecutable</key>
    <string>${launcher_executable}</string>
    <key>CFBundleIdentifier</key>
    <string>${bundle_identifier}</string>
    <key>CFBundleIconFile</key>
    <string>${icon_name}</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>${app_name}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${version}</string>
    <key>CFBundleVersion</key>
    <string>${version}</string>
    <key>LSMinimumSystemVersion</key>
    <string>${minimum_macos}</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
EOF

echo "Creating zip archive..."
(
    cd "$dist_dir"
    /usr/bin/ditto -c -k --sequesterRsrc --keepParent "$bundle_name" "$zip_name"
    /usr/bin/shasum -a 256 "$zip_name" > "$checksum_name"
)

echo "Created app bundle: $app_bundle"
echo "Created zip archive: $zip_path"
echo "Created checksum: $checksum_path"
