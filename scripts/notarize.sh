#!/usr/bin/env bash
# Notarizes dist/Aloud.app and dist/Aloud.dmg with an App Store Connect API key,
# staples both, and hard-gates on Gatekeeper acceptance.
#
# Credentials, either:
#   - env: ASC_KEY_ID, ASC_ISSUER_ID, and ASC_KEY_P8 (key contents) or ASC_KEY_PATH
#   - or a stored keychain profile:  xcrun notarytool store-credentials aloud ...
#     then run with NOTARY_PROFILE=aloud.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$DIR"

APP="dist/Aloud.app"
DMG="dist/Aloud.dmg"
[ -d "$APP" ] || { echo "error: $APP missing" >&2; exit 1; }

NOTARY_ARGS=()
if [ -n "${NOTARY_PROFILE:-}" ]; then
  NOTARY_ARGS=(--keychain-profile "$NOTARY_PROFILE")
else
  : "${ASC_KEY_ID:?set ASC_KEY_ID or NOTARY_PROFILE}"
  : "${ASC_ISSUER_ID:?set ASC_ISSUER_ID}"
  KEY_PATH="${ASC_KEY_PATH:-}"
  if [ -z "$KEY_PATH" ]; then
    : "${ASC_KEY_P8:?set ASC_KEY_P8 (key contents) or ASC_KEY_PATH}"
    KEY_PATH="$(mktemp -d)/AuthKey_${ASC_KEY_ID}.p8"
    printf '%s' "$ASC_KEY_P8" > "$KEY_PATH"
  fi
  NOTARY_ARGS=(--key "$KEY_PATH" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID")
fi

echo "==> Notarizing app"
ZIP="$(mktemp -d)/notarize.zip"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" "${NOTARY_ARGS[@]}" --wait
xcrun stapler staple "$APP"
spctl -a -vvv -t exec "$APP"   # must report: accepted, Notarized Developer ID

if [ -f "$DMG" ]; then
  echo "==> Notarizing dmg"
  xcrun notarytool submit "$DMG" "${NOTARY_ARGS[@]}" --wait
  xcrun stapler staple "$DMG"
  spctl -a -vvv -t open --context context:primary-signature "$DMG"
fi

echo "==> Notarization complete"
