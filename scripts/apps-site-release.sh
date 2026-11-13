#!/bin/bash
# Publishes a release DMG to apps.goodvantage.cloud: the steps of the
# apps-site job in .forgejo/workflows/release.yml, kept here so that
# scripts/tests/test_apps_site_release.py can run them before a tag does.
#
#   scripts/apps-site-release.sh notes TAG NOTES_FILE
#       Writes the annotated tag's message to NOTES_FILE as release notes,
#       or leaves the file empty: a lightweight tag, or a message that only
#       names the version (as scripts/release.sh writes it), has no notes.
#       Fetches the tag object from origin first. Never fails over notes.
#
#   scripts/apps-site-release.sh publish TAG ARTIFACTS_DIR [NOTES_FILE]
#       Publishes the one Nevermore-<version>-macos-universal.dmg under
#       ARTIFACTS_DIR as version TAG (without its leading v) on the site,
#       with scripts/publish_app_release.py. Reads APPS_SITE_URL and
#       APPS_SITE_TOKEN from the environment. X.Y.Z goes to the stable
#       channel, X.Y.Z-prerelease to beta.
set -euo pipefail

scripts_dir="$(cd "$(dirname "$0")" && pwd)"
app_id=nevermore
app_name=Nevermore
description="Native Mac client for Raven, Frappe's self-hosted chat."
# Resources/Info.plist's LSMinimumSystemVersion; build-app.sh builds both
# architectures for releases.
macos_label="macOS 26 or later (Apple silicon and Intel)"

usage() {
  sed -n '6,17s/^# \{0,1\}//p' "$0" >&2
  exit 2
}

notes() {
  local tag=$1 notes_file=$2 contents signature message
  : > "$notes_file"

  if ! git fetch --quiet --no-tags --depth=1 origin "+refs/tags/$tag:refs/tags/$tag"; then
    echo "::warning::Could not fetch the tag $tag; publishing without release notes."
    return 0
  fi
  if [[ "$(git cat-file -t "refs/tags/$tag")" != tag ]]; then
    echo "$tag is a lightweight tag; publishing without release notes."
    return 0
  fi

  # %(contents) ends with the tag's signature, if it is signed.
  contents="$(git for-each-ref --format='%(contents)' "refs/tags/$tag")"
  signature="$(git for-each-ref --format='%(contents:signature)' "refs/tags/$tag")"
  # Command substitution drops the trailing newlines.
  message="$(printf '%s' "${contents%"$signature"}")"
  case "$message" in
    '' | "$tag" | "${tag#v}" | "$app_name $tag" | "$app_name ${tag#v}")
      echo "The message of $tag only names the version; publishing without release notes."
      return 0
      ;;
  esac
  printf '%s\n' "$message" > "$notes_file"
  echo "Release notes from $tag:"
  cat "$notes_file"
}

publish() {
  local tag=$1 artifacts=$2 notes_file=${3:-} version dmg
  version="${tag#v}"
  local found=()
  while IFS= read -r -d '' dmg; do
    found+=("$dmg")
  done < <(find "$artifacts" -type f -name "$app_name-*-macos-universal.dmg" -print0)
  case "${#found[@]}" in
    0) echo "::error::No $app_name-*-macos-universal.dmg under $artifacts"; exit 1 ;;
    1) dmg="${found[0]}" ;;
    *) echo "::error::More than one DMG under $artifacts: ${found[*]}"; exit 1 ;;
  esac
  if [[ "$(basename "$dmg")" != "$app_name-$version-macos-universal.dmg" ]]; then
    echo "::error::$(basename "$dmg") does not belong to $tag"
    exit 1
  fi

  local args=(release --app "$app_id" --name "$app_name" --description "$description"
    --version "$version" --file "macos=$dmg=$macos_label")
  if [[ -n "$notes_file" && -s "$notes_file" ]]; then
    args+=(--notes-file "$notes_file")
  fi
  python3 "$scripts_dir/publish_app_release.py" "${args[@]}"
}

case "${1:-}" in
  notes)
    [[ $# -eq 3 ]] || usage
    notes "$2" "$3"
    ;;
  publish)
    [[ $# -eq 3 || $# -eq 4 ]] || usage
    publish "$2" "$3" "${4:-}"
    ;;
  *)
    usage
    ;;
esac
