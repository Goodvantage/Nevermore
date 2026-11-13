#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
configuration="${CONFIGURATION:-release}"
swift_build=(swift build)
# CI runs as a LaunchDaemon, where SwiftPM's Keychain credential lookup fails
# even for public binary downloads. This does not affect codesign's keychain.
if [[ "${CI:-}" == true ]]; then swift_build+=(--disable-keychain); fi
# lkm-build (scripts/build.sh) drives this script with --debug/--release;
# an explicit flag wins over the CONFIGURATION environment default.
for arg in "$@"; do
  case "$arg" in
    --debug) configuration=debug ;;
    --release) configuration=release ;;
    *) echo "Unknown option '$arg' (want --debug or --release)" >&2; exit 2 ;;
  esac
done
app_path="$PWD/build/Nevermore.app"
# Swift Build can otherwise compile for the host SDK's OS version while the
# linker still records Package.swift's minimum. Enforce availability checking
# for the same minimum declared by the packaged app, for every architecture.
minimum_os="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' Resources/Info.plist)"
[[ "$minimum_os" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || { echo 'Invalid minimum macOS version' >&2; exit 1; }
build_target="$(uname -m)-apple-macosx$minimum_os"
# Resolve the signing identity before the slow build so a keychain problem
# fails in seconds. resolve-sign-identity.sh documents the selection rules.
identity="$(scripts/resolve-sign-identity.sh)"
sign_options=(--force)
# Ad-hoc test builds have no Team ID, so Hardened Runtime's library validation
# rejects even their re-signed Sparkle framework. Keep Hardened Runtime for
# certificate-signed builds; package-release.sh requires Developer ID.
if [[ "$identity" != - ]]; then sign_options+=(--options runtime); fi
sign_timestamp=(--timestamp=none)
if [[ "$identity" == 'Developer ID Application:'* ]]; then sign_timestamp=(--timestamp); fi
# Assemble from scratch: cp -R merges into an existing bundle and cannot
# replace a stale directory with a file (or drop removed resources), so a
# leftover Nevermore.app from an older Sparkle breaks the copy below.
rm -rf "$app_path"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
if [[ "${UNIVERSAL:-0}" == 1 ]]; then
  # --arch and --triple are mutually exclusive. Build explicit per-architecture
  # triples, then merge; do not infer compatibility from a linker-only override.
  slice_directory="$(mktemp -d "${TMPDIR:-/tmp}/NevermoreSlices.XXXXXX")"
  trap 'rm -rf "$slice_directory"' EXIT
  for architecture in arm64 x86_64; do
    "${swift_build[@]}" -c "$configuration" --triple "$architecture-apple-macosx$minimum_os"
    binary_path="$("${swift_build[@]}" -c "$configuration" --triple "$architecture-apple-macosx$minimum_os" --show-bin-path)"
    cp "$binary_path/Nevermore" "$slice_directory/Nevermore-$architecture"
  done
  lipo -create "$slice_directory/Nevermore-arm64" "$slice_directory/Nevermore-x86_64" -output "$app_path/Contents/MacOS/Nevermore"
else
  "${swift_build[@]}" -c "$configuration" --triple "$build_target"
  binary_path="$("${swift_build[@]}" -c "$configuration" --triple "$build_target" --show-bin-path)"
  cp "$binary_path/Nevermore" "$app_path/Contents/MacOS/"
fi
cp Resources/Info.plist "$app_path/Contents/Info.plist"
cp Resources/Nevermore.icns "$app_path/Contents/Resources/"
cp -R Resources/Licenses "$app_path/Contents/Resources/"
# SwiftPM resource bundles, including Core localization and GRDB privacy data.
for resource in "$binary_path/"*.bundle; do
  [[ ! -d "$resource" ]] || cp -R "$resource" "$app_path/Contents/Resources/"
done
mkdir -p "$app_path/Contents/Frameworks"
cp -R "$binary_path/Sparkle.framework" "$app_path/Contents/Frameworks/"
framework="$app_path/Contents/Frameworks/Sparkle.framework/Versions/B"
for component in "$framework/XPCServices/Installer.xpc" "$framework/XPCServices/Downloader.xpc" "$framework/Autoupdate" "$framework/Updater.app"; do
  codesign "${sign_options[@]}" "${sign_timestamp[@]}" --preserve-metadata=entitlements --sign "$identity" "$component"
done
codesign "${sign_options[@]}" "${sign_timestamp[@]}" --sign "$identity" "$app_path/Contents/Frameworks/Sparkle.framework"
if [[ -n "${UPDATE_FEED_URL:-}" || -n "${UPDATE_PUBLIC_KEY:-}" ]]; then
  : "${UPDATE_FEED_URL:?Set both update feed URL and public key}"
  : "${UPDATE_PUBLIC_KEY:?Set both update feed URL and public key}"
  [[ "$UPDATE_FEED_URL" == https://* ]] || { echo 'Update feed must use HTTPS' >&2; exit 1; }
  /usr/libexec/PlistBuddy -c "Add :SUFeedURL string $UPDATE_FEED_URL" "$app_path/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Add :SUPublicEDKey string $UPDATE_PUBLIC_KEY" "$app_path/Contents/Info.plist"
fi
codesign "${sign_options[@]}" "${sign_timestamp[@]}" --entitlements Resources/Nevermore.entitlements --sign "$identity" "$app_path"
codesign --verify --deep --strict "$app_path"
printf '%s\n' "$app_path"
