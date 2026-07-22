#!/usr/bin/env bash
# Builds Aloud.app into dist/. Signs with $CODESIGN_IDENTITY (Developer ID +
# hardened runtime + timestamp — notarization-ready) when set, else ad-hoc.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$DIR"

VERSION="${1:-0.0.0}"
case "$VERSION" in (*[!0-9.]*) VERSION="0.0.0" ;; esac

echo "==> swift build -c release"
swift build -c release

APP="dist/Aloud.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Aloud "$APP/Contents/MacOS/Aloud"

# App icon (generated + committed; regenerate with scripts/make-icon.sh).
if [ -f Resources/AppIcon.icns ]; then
  cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Aloud</string>
  <key>CFBundleDisplayName</key><string>Aloud</string>
  <key>CFBundleIdentifier</key><string>com.abrahamgonzalez.aloud</string>
  <key>CFBundleExecutable</key><string>Aloud</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIconName</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSMicrophoneUsageDescription</key>
  <string>Aloud uses the microphone to hear what you say while you hold the dictation key. Audio never leaves your Mac.</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
</dict>
</plist>
PLIST

# Sign. The SPM linker leaves an inconsistent partial signature on the inner
# binary; without a proper re-sign a quarantined download reports "damaged".
# Developer ID (CI release): hardened runtime + timestamp + entitlements —
# the prerequisites for notarization. Otherwise ad-hoc so local/PR builds
# still verify.
if [ -n "${CODESIGN_IDENTITY:-}" ]; then
  echo "==> Code-signing with Developer ID ($CODESIGN_IDENTITY)"
  SIGN_ARGS=(--force --options runtime --timestamp --entitlements Resources/Aloud.entitlements --sign "$CODESIGN_IDENTITY")
else
  echo "==> Ad-hoc code-signing (no Developer ID — not notarizable)"
  SIGN_ARGS=(--force --timestamp=none --sign -)
fi
codesign "${SIGN_ARGS[@]}" "$APP/Contents/MacOS/Aloud"
codesign "${SIGN_ARGS[@]}" "$APP"
codesign --verify --strict "$APP"   # hard gate
echo "    signature verified"

echo "==> Built $APP (v$VERSION)"
