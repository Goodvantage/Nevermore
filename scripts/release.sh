#!/usr/bin/env bash
# Cuts a release: bumps CFBundleShortVersionString in Resources/Info.plist
# and increments CFBundleVersion, commits, tags "v<version>", and with
# --push pushes branch + tag, which triggers .forgejo/workflows/release.yml
# to sign, notarize and publish the DMG on the forge and on
# apps.goodvantage.cloud. A prerelease such as 0.2.0-beta.1 goes to the
# site's beta channel. The annotated tag's message becomes the release
# notes; docs/implementation/OPERATIONS.md shows how to write them.
#
# Usage: scripts/release.sh [X.Y.Z[-prerelease]] [--push]
# Shared engine: https://github.com/L-K-M/release-tool (this stub only sets config).
set -euo pipefail
export RELEASE_APP_NAME="Nevermore"
export RELEASE_KIND="plist"
export RELEASE_PLIST="Resources/Info.plist"
# Semantic Versioning, as apps.goodvantage.cloud requires.
source "$(dirname "${BASH_SOURCE[0]}")/semver-pattern.sh"
export RELEASE_VERSION_REGEX="$SEMVER_PATTERN"
# CFBundleVersion is the build number Sparkle compares; every release
# raises it by one.
export RELEASE_POST_BUMP='build="$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" Resources/Info.plist)" && [[ "$build" =~ ^[0-9]+$ ]] && /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $((build + 1))" Resources/Info.plist'
export RELEASE_CI_NOTE="Forgejo (release.yml) will now sign, notarize and publish <tag> on the forge and on apps.goodvantage.cloud."
export RELEASE_INVOKED_AS="scripts/release.sh"
BIN="${LKM_RELEASE_BIN:-lkm-release}"
command -v "$BIN" >/dev/null 2>&1 || {
  echo "error: lkm-release not found — clone https://github.com/L-K-M/release-tool and run ./install.sh" >&2
  exit 1
}
exec "$BIN" "$@"
