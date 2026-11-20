#!/bin/zsh

set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/release-common.sh"

function usage() {
    cat <<'EOF'
Verify the packaged dist/Fyluro.app actually works, from a copy relocated
outside the repo. Testing in place can't distinguish a real fix from a
build-machine fallback that quietly "works" only where the app was built.
(FyluroCore no longer ships a SwiftPM resource bundle -- the camera catalog
is now a user file -- but if a bundled resource is ever added again, this is
the check that catches Bundle.module placement bugs.)

Usage:
  scripts/release-app-smoke-test.sh --version <version> [--with-launcher-check]

--with-launcher-check additionally launches the real fyluro-launcher binary
against a disposable fake "SD card" (a small HFS+ disk image with a DCIM
folder) to verify the automatic-scan-on-launch path doesn't crash. This is
NOT run automatically by release-prepare.sh -- run it manually before
shipping any release that touches launcher startup or auto-scan code, since
it depends on window-server/session behavior on the machine running it and
can be flakier than the mandatory CLI check.
EOF
}

version=""
with_launcher_check=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version)
            shift
            [[ $# -gt 0 ]] || release_die "--version requires a value"
            version="$1"
            ;;
        --with-launcher-check)
            with_launcher_check=1
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
release_validate_version "$version"

release_require_command jq
release_require_command shasum
release_require_command ditto
release_require_command /usr/libexec/PlistBuddy

app_bundle_name="${RELEASE_APP_NAME}.app"
app_bundle_src="$(release_app_bundle_path)"

[[ -d "$app_bundle_src" ]] || release_die "packaged app bundle not found: $app_bundle_src (run scripts/package-macos-app.sh --version $version first)"

info_plist="$app_bundle_src/Contents/Info.plist"
[[ -f "$info_plist" ]] || release_die "packaged app bundle missing Info.plist: $info_plist"

packaged_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$info_plist" 2>/dev/null || true)"
[[ "$packaged_version" == "$version" ]] || release_die "packaged app version ($packaged_version) does not match requested version ($version); rerun scripts/package-macos-app.sh --version $version"

bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$info_plist" 2>/dev/null || true)"
[[ "$bundle_id" == "com.thanosam.fyluro" ]] || release_die "packaged app Info.plist CFBundleIdentifier is '$bundle_id', expected com.thanosam.fyluro"

for icon_file in Assets.car AppIcon.icns; do
    [[ -f "$app_bundle_src/Contents/Resources/$icon_file" ]] || release_die "packaged app bundle missing icon resource: $icon_file"
done
icon_name="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconName' "$info_plist" 2>/dev/null || true)"
[[ "$icon_name" == "AppIcon" ]] || release_die "packaged app Info.plist CFBundleIconName is '$icon_name', expected AppIcon"

temp_root="$(mktemp -d "${TMPDIR:-/tmp}/fyluro-app-smoke.XXXXXX")"
temp_app_bundle="$temp_root/$app_bundle_name"

image_path=""
mount_point=""
launcher_pid=""

function cleanup() {
    if [[ -n "$launcher_pid" ]]; then
        kill "$launcher_pid" >/dev/null 2>&1 || true
        wait "$launcher_pid" 2>/dev/null || true
    fi
    if [[ -n "$mount_point" ]]; then
        hdiutil detach "$mount_point" -force >/dev/null 2>&1 || true
    fi
    rm -rf "$temp_root"
    [[ -n "$image_path" && -f "$image_path" ]] && rm -f "$image_path"
}

trap cleanup EXIT

release_note "Relocating packaged app outside the repo (this is what makes the check meaningful -- see usage)..."
/usr/bin/ditto "$app_bundle_src" "$temp_app_bundle"

/usr/bin/codesign --verify --deep --strict "$temp_app_bundle" || release_die "relocated app bundle failed codesign verification"

cli_binary="$temp_app_bundle/Contents/MacOS/fyluro"
[[ -x "$cli_binary" ]] || release_die "relocated app bundle missing CLI binary: $cli_binary"

release_note "Running ingest smoke checks against the packaged CLI binary..."
release_smoke_run_ingest_fixture_suite "$cli_binary" "$temp_root/cli-smoke"

release_note "Packaged app CLI smoke checks passed."

if (( with_launcher_check )); then
    release_require_command hdiutil

    launcher_binary="$temp_app_bundle/Contents/MacOS/fyluro-launcher"
    [[ -x "$launcher_binary" ]] || release_die "relocated app bundle missing launcher binary: $launcher_binary"

    release_note "Creating disposable fake SD card for launcher auto-scan check..."
    fixture_root="$temp_root/fake-sd-card"
    mkdir -p "$fixture_root/DCIM/100RKSMK"
    : > "$fixture_root/DCIM/100RKSMK/IMG_0001.JPG"

    image_path="$temp_root/rksmoke.dmg"
    hdiutil create -quiet -size 10m -fs HFS+ -volname RKSMOKE -srcfolder "$fixture_root" "$image_path" >/dev/null

    mount_point="/Volumes/RKSMOKE"
    hdiutil attach -quiet -nobrowse -mountpoint "$mount_point" "$image_path" >/dev/null

    diagnostic_reports_dir="$HOME/Library/Logs/DiagnosticReports"
    launch_marker="$(mktemp "${TMPDIR:-/tmp}/fyluro-launcher-marker.XXXXXX")"

    release_note "Launching packaged fyluro-launcher against the fake SD card..."
    "$launcher_binary" >/dev/null 2>&1 &
    launcher_pid=$!

    sleep 5

    if ! kill -0 "$launcher_pid" 2>/dev/null; then
        release_die "fyluro-launcher exited/crashed during the auto-scan launcher check"
    fi

    if [[ -d "$diagnostic_reports_dir" ]]; then
        while IFS= read -r -d '' report; do
            if [[ "$report" -nt "$launch_marker" ]]; then
                release_die "fyluro-launcher produced a new crash report during the auto-scan launcher check: $report"
            fi
        done < <(find "$diagnostic_reports_dir" -maxdepth 1 -name 'fyluro-launcher-*' -print0 2>/dev/null)
    fi

    rm -f "$launch_marker"

    kill "$launcher_pid" >/dev/null 2>&1 || true
    wait "$launcher_pid" 2>/dev/null || true
    launcher_pid=""

    hdiutil detach "$mount_point" -force >/dev/null 2>&1 || true
    mount_point=""

    release_note "Packaged app launcher auto-scan check passed."
fi

release_note "Packaged app smoke checks passed."
