#!/usr/bin/env bash
# Build ScreenBar.app and install it to ~/Applications.
#
# Builds in /private/tmp on purpose: files created anywhere under $HOME get a
# com.apple.provenance xattr that makes `codesign` fail on a Swift binary.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="ScreenBar"
BUILD="/private/tmp/${APP_NAME}-build.$$"
APP="${BUILD}/${APP_NAME}.app"
DEST="${HOME}/Applications/${APP_NAME}.app"

trap 'rm -rf "$BUILD"' EXIT

mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"
cp "${REPO}/Resources/Info.plist" "${APP}/Contents/Info.plist"
cp "${REPO}/Resources/AppIcon.icns" "${APP}/Contents/Resources/AppIcon.icns"

swiftc -O \
  -target arm64-apple-macos13.0 \
  -framework AppKit -framework ServiceManagement \
  -o "${APP}/Contents/MacOS/${APP_NAME}" \
  "${REPO}/Sources/main.swift"

codesign --force --sign - --identifier com.thekitchenstudio.screenbar "$APP"
codesign --verify --strict "$APP"

# Optional: `scripts/build.sh --dmg <folder>` also writes ScreenBar.dmg into <folder>.
if [ "${1:-}" = "--dmg" ]; then
  OUT="${2:?usage: build.sh --dmg <folder>}"
  STAGE="${BUILD}/dmg"
  mkdir -p "$STAGE" "$OUT"
  cp -R "$APP" "$STAGE/"
  ln -s /Applications "$STAGE/Applications"
  rm -f "${OUT}/${APP_NAME}.dmg"
  hdiutil create -quiet -volname "$APP_NAME" -srcfolder "$STAGE" -fs HFS+ -format UDZO "${OUT}/${APP_NAME}.dmg"
  echo "dmg: ${OUT}/${APP_NAME}.dmg"
fi

mkdir -p "${HOME}/Applications"
if [ -d "$DEST" ]; then
  pkill -x "$APP_NAME" 2>/dev/null || true
  sleep 0.5
  rm -rf "$DEST"
fi
cp -R "$APP" "$DEST"

echo "installed: $DEST"
