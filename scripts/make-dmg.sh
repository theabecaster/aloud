#!/usr/bin/env bash
# Wraps dist/Aloud.app in a polished drag-to-Applications DMG at dist/Aloud.dmg:
# custom volume icon, instructional background with an arrow, positioned icons,
# and the app icon on the .dmg file itself. Uses create-dmg (brew) when
# available; falls back to a plain hdiutil image otherwise so the pipeline
# never hard-fails on a missing tool.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$DIR"

APP="dist/Aloud.app"
DMG="dist/Aloud.dmg"
[ -d "$APP" ] || { echo "error: $APP missing — run scripts/make-app.sh first" >&2; exit 1; }

# Background is generated + committed; regenerate if missing.
[ -f Resources/dmg-background@2x.png ] || bash scripts/make-dmg-background.sh

rm -f "$DMG"

if command -v create-dmg >/dev/null 2>&1; then
  echo "==> create-dmg (styled window)"
  # 660x420 window; app icon left, Applications link right; icons 128pt.
  # create-dmg exits 2 when it couldn't apply Finder styling (headless CI
  # quirk) but still produced a valid image — accept that.
  set +e
  create-dmg \
    --volname "Aloud" \
    --volicon "Resources/AppIcon.icns" \
    --background "Resources/dmg-background@2x.png" \
    --window-pos 200 160 \
    --window-size 660 420 \
    --icon-size 128 \
    --icon "Aloud.app" 170 210 \
    --app-drop-link 490 210 \
    --hide-extension "Aloud.app" \
    --no-internet-enable \
    "$DMG" "$APP"
  status=$?
  set -e
  if [ ! -f "$DMG" ]; then
    echo "error: create-dmg failed (exit $status) and produced no image" >&2
    exit 1
  fi
else
  echo "==> hdiutil fallback (plain window; brew install create-dmg for the styled one)"
  STAGE="$(mktemp -d)"
  trap 'rm -rf "$STAGE"' EXIT
  cp -R "$APP" "$STAGE/Aloud.app"
  ln -s /Applications "$STAGE/Applications"
  hdiutil create -volname "Aloud" -srcfolder "$STAGE" -ov -format UDZO -quiet "$DMG"
fi

# Put the app icon on the .dmg file itself (what the user sees in Downloads).
if command -v fileicon >/dev/null 2>&1; then
  fileicon set "$DMG" "Resources/AppIcon.icns" >/dev/null && echo "==> DMG file icon set"
fi

# Sign the DMG when we have an identity (required for stapling it).
if [ -n "${CODESIGN_IDENTITY:-}" ]; then
  codesign --force --timestamp --sign "$CODESIGN_IDENTITY" "$DMG"
fi

echo "==> Built $DMG"
