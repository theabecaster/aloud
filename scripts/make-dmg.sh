#!/usr/bin/env bash
# Wraps dist/Aloud.app in a drag-to-Applications DMG at dist/Aloud.dmg.
# Pure hdiutil — no third-party dmg tooling.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$DIR"

APP="dist/Aloud.app"
DMG="dist/Aloud.dmg"
[ -d "$APP" ] || { echo "error: $APP missing — run scripts/make-app.sh first" >&2; exit 1; }

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/Aloud.app"
ln -s /Applications "$STAGE/Applications"

rm -f "$DMG"
hdiutil create -volname "Aloud" -srcfolder "$STAGE" -ov -format UDZO -quiet "$DMG"

# Sign the DMG itself when we have an identity (required for stapling it).
if [ -n "${CODESIGN_IDENTITY:-}" ]; then
  codesign --force --timestamp --sign "$CODESIGN_IDENTITY" "$DMG"
fi

echo "==> Built $DMG"
