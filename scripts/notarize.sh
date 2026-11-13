#!/bin/bash
# Notarizes a signed .zip or .dmg and waits for Apple's verdict. Stapling is
# left to the caller: for an app, the .zip is submitted but the .app inside
# it is stapled.
#
# Usage, with an App Store Connect API key (CI):
#   NOTARY_KEY_FILE=AuthKey.p8 NOTARY_KEY_ID=ABC123 NOTARY_ISSUER_ID=<uuid> \
#     scripts/notarize.sh <file>
# or with a notarytool keychain profile (`xcrun notarytool store-credentials`):
#   NOTARY_PROFILE=nevermore-release scripts/notarize.sh <file>
#
# Apple's queue has no service level: a submission usually finishes in
# minutes but can take hours. The file is uploaded once, then the script
# waits on that submission in rounds of NOTARY_WAIT_TIMEOUT (default 30m),
# NOTARY_WAIT_ROUNDS times (default 4). A round that ends without a verdict
# waits again instead of uploading again. An Invalid or Rejected verdict
# prints Apple's log and fails; so does any other notarytool error.
set -euo pipefail

file="${1:?usage: scripts/notarize.sh <file>}"
[[ -f "$file" ]] || { echo "error: $file does not exist" >&2; exit 1; }

if [[ -n "${NOTARY_KEY_FILE:-}" ]]; then
  : "${NOTARY_KEY_ID:?NOTARY_KEY_ID is required with NOTARY_KEY_FILE}"
  : "${NOTARY_ISSUER_ID:?NOTARY_ISSUER_ID is required with NOTARY_KEY_FILE}"
  auth=(--key "$NOTARY_KEY_FILE" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID")
elif [[ -n "${NOTARY_PROFILE:-}" ]]; then
  auth=(--keychain-profile "$NOTARY_PROFILE")
else
  echo 'error: set NOTARY_KEY_FILE, NOTARY_KEY_ID and NOTARY_ISSUER_ID, or NOTARY_PROFILE' >&2
  exit 1
fi

wait_timeout="${NOTARY_WAIT_TIMEOUT:-30m}"
rounds="${NOTARY_WAIT_ROUNDS:-4}"
[[ "$rounds" =~ ^[1-9][0-9]*$ ]] || rounds=4

# json_field FIELD: prints FIELD from the JSON on stdin, or nothing.
json_field() { /usr/bin/plutil -extract "$1" raw -o - - 2>/dev/null || true; }

echo "Submitting $(basename "$file") for notarization"
status=0
output="$(xcrun notarytool submit "$file" "${auth[@]}" --output-format json)" || status=$?
id="$(printf '%s' "$output" | json_field id)"
if [[ -z "$id" ]]; then
  printf 'error: notarytool submit returned no submission id (exit %s):\n%s\n' "$status" "$output" >&2
  exit 1
fi
echo "Submission $id"

verdict=''
for ((round = 1; round <= rounds; round++)); do
  status=0
  output="$(xcrun notarytool wait "$id" "${auth[@]}" --timeout "$wait_timeout" --output-format json)" || status=$?
  verdict="$(printf '%s' "$output" | json_field status)"
  case "$verdict" in
    Accepted | Invalid | Rejected) break ;;
  esac
  # A wait that fails without a verdict may only have reached --timeout,
  # which notarytool reports in no documented wording. Ask for the
  # submission's state instead: if that fails too (a bad key, the network),
  # the failure is real.
  if [[ "$status" -ne 0 ]]; then
    info_status=0
    info="$(xcrun notarytool info "$id" "${auth[@]}" --output-format json)" || info_status=$?
    verdict="$(printf '%s' "$info" | json_field status)"
    if [[ "$info_status" -ne 0 || -z "$verdict" ]]; then
      printf 'error: notarytool wait failed for %s (exit %s):\n%s\n%s\n' "$id" "$status" "$output" "$info" >&2
      exit 1
    fi
    case "$verdict" in
      Accepted | Invalid | Rejected) break ;;
    esac
  fi
  echo "Still processing (${verdict:-no status}) after round $round of $rounds ($wait_timeout each)"
done

case "$verdict" in
  Accepted)
    echo "Notarization accepted ($id)"
    ;;
  Invalid | Rejected)
    xcrun notarytool log "$id" "${auth[@]}" >&2 || true
    echo "error: notarization of $(basename "$file") ended $verdict" >&2
    exit 1
    ;;
  *)
    echo "error: no verdict for $id after $rounds rounds of $wait_timeout; Apple's queue is backed up. Check 'xcrun notarytool info $id' and re-run the job once it is done." >&2
    exit 1
    ;;
esac
