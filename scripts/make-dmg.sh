#!/bin/bash
# Build a distributable DMG from a built MacCam.app.
# Usage: scripts/make-dmg.sh path/to/MacCam.app [version]
set -euo pipefail

APP="${1:?usage: make-dmg.sh path/to/MacCam.app [version]}"
VERSION="${2:-${GITHUB_REF_NAME:-dev}}"
NAME="MacCam"
DIST="dist"
DMG="$DIST/${NAME}-${VERSION}.dmg"

if [ ! -d "$APP" ]; then
  echo "error: app not found at $APP" >&2
  exit 1
fi

mkdir -p "$DIST"
STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT

cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

rm -f "$DMG"
hdiutil create \
  -volname "$NAME" \
  -srcfolder "$STAGING" \
  -ov -format UDZO \
  "$DMG"

echo "Created $DMG"
