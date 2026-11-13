#!/bin/bash
# Builds the universal release app, signs it with a Developer ID, notarizes
# and staples it, and packages it as a signed, notarized and stapled DMG:
#
#   build/Nevermore-<version>-macos-universal.dmg (and .sha256 beside it)
#
# <version> is CFBundleShortVersionString in Resources/Info.plist. Prints
# the DMG's path last.
#
# Needs SIGN_IDENTITY, a "Developer ID Application: …" identity in the
# keychain search list, and the notarization credentials scripts/notarize.sh
# describes: NOTARY_PROFILE locally, or NOTARY_KEY_FILE, NOTARY_KEY_ID and
# NOTARY_ISSUER_ID in CI.
set -euo pipefail
cd "$(dirname "$0")/.."
: "${SIGN_IDENTITY:?Set SIGN_IDENTITY to the Developer ID Application identity}"
[[ "$SIGN_IDENTITY" == 'Developer ID Application:'* ]] || { echo 'Developer ID Application identity required' >&2; exit 1; }
if [[ -z "${NOTARY_PROFILE:-}" && -z "${NOTARY_KEY_FILE:-}" ]]; then
  echo 'Set NOTARY_PROFILE, or NOTARY_KEY_FILE with NOTARY_KEY_ID and NOTARY_ISSUER_ID' >&2
  exit 1
fi

source scripts/semver-pattern.sh
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
[[ "$version" =~ $SEMVER_PATTERN ]] || { echo "CFBundleShortVersionString '$version' is not a semantic version (scripts/semver-pattern.sh)" >&2; exit 1; }
app=build/Nevermore.app
dmg="build/Nevermore-$version-macos-universal.dmg"
notarize_zip=build/Nevermore-notarize.zip

CONFIGURATION=release UNIVERSAL=1 ./scripts/build-app.sh
codesign --force --options runtime --timestamp --entitlements Resources/Nevermore.entitlements --sign "$SIGN_IDENTITY" "$app"

# The dependency notices ship inside the app.
for notice in Resources/Licenses/*; do
  [[ -s "$app/Contents/Resources/Licenses/$(basename "$notice")" ]] || { echo "error: $app lacks the notice $(basename "$notice")" >&2; exit 1; }
done

# A zip cannot carry a staple, so submit a zip and staple the app itself.
ditto -c -k --sequesterRsrc --keepParent "$app" "$notarize_zip"
./scripts/notarize.sh "$notarize_zip"
rm -f "$notarize_zip"
xcrun stapler staple "$app"
spctl --assess --type execute --verbose "$app"

stage="$(mktemp -d "${TMPDIR:-/tmp}/NevermoreDMG.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
ditto "$app" "$stage/Nevermore.app"
ln -s /Applications "$stage/Applications"
hdiutil create -volname Nevermore -srcfolder "$stage" -ov -format UDZO "$dmg"
codesign --force --timestamp --sign "$SIGN_IDENTITY" "$dmg"
./scripts/notarize.sh "$dmg"
xcrun stapler staple "$dmg"
xcrun stapler validate "$dmg"
# The verdict a downloading Mac reaches.
spctl --assess --type open --context context:primary-signature --verbose "$dmg"
(cd build && shasum -a 256 "$(basename "$dmg")" > "$(basename "$dmg").sha256")
printf '%s\n' "$dmg"
