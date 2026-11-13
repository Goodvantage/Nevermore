#!/bin/bash
# Prints the identity build-app.sh passes to `codesign --sign`.
#
# An explicit SIGN_IDENTITY wins verbatim: CI passes "-" (ad hoc) and
# package-release.sh a Developer ID name. Otherwise this picks a valid
# "Apple Development" identity from the keychain search list and prints its
# SHA-1 hash. A name is only a search string to codesign, which refuses to
# sign when it matches more than one certificate ("ambiguous"), as on a Mac
# with Apple Development certificates for two accounts; a hash names exactly
# one certificate.
#
# With several valid identities the name that sorts first byte by byte wins
# (LC_ALL=C: uppercase before lowercase, whatever the user's locale), so every
# build on a Mac picks the same certificate. The designated requirement pins
# that certificate's common name, and macOS ties the app's keychain items
# (account tokens) to it: a build signed with another certificate cannot
# read them silently. A renewed certificate keeps its name, so the choice
# survives renewals and keychain reordering.
set -euo pipefail

if [[ -n "${SIGN_IDENTITY:-}" ]]; then
  printf '%s\n' "$SIGN_IDENTITY"
  exit 0
fi

listing="$(security find-identity -v -p codesigning)" || {
  echo 'error: could not list code-signing identities (security find-identity failed)' >&2
  exit 1
}

# Listing lines look like:   1) 0123…CDEF "Apple Development: Name (ABCDE12345)"
# Each candidate becomes "<name><TAB><hash>". The same certificate in two
# keychains is listed twice; sort -u collapses it, as codesign tolerates it.
pattern='^ *[0-9]+\) ([0-9A-F]{40}) "(Apple Development: .*)"$'
candidates=''
while IFS= read -r line; do
  [[ "$line" =~ $pattern ]] || continue
  candidates+="${BASH_REMATCH[2]}"$'\t'"${BASH_REMATCH[1]}"$'\n'
done <<< "$listing"
candidates="$(printf '%s' "$candidates" | LC_ALL=C sort -u)"

if [[ -z "$candidates" ]]; then
  cat >&2 <<'EOF'
error: no valid Apple Development code-signing identity in the keychain.
Add one in Xcode > Settings > Accounts > Manage Certificates, or set
SIGN_IDENTITY to an identity from `security find-identity -v -p codesigning`
(SIGN_IDENTITY=- signs ad hoc).
EOF
  exit 1
fi

chosen="${candidates%%$'\n'*}"
chosen_name="${chosen%$'\t'*}"
chosen_hash="${chosen##*$'\t'}"

if [[ "$candidates" == *$'\n'* ]]; then
  echo "note: several Apple Development identities found; signing with \"$chosen_name\"." >&2
  echo 'note: to sign with another, set SIGN_IDENTITY to its SHA-1 hash:' >&2
  while IFS=$'\t' read -r name hash; do
    printf '  %s  %s\n' "$hash" "$name" >&2
  done <<< "$candidates"
fi

printf '%s\n' "$chosen_hash"
