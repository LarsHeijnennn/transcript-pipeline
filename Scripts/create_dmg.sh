#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
APP_DIR="$PROJECT_DIR/Release/Transcript Pipeline.app"
DMG_PATH="$PROJECT_DIR/Release/Transcript-Pipeline-unsigned.dmg"
STAGING_DIR="$PROJECT_DIR/Release/dmg-staging"

"$PROJECT_DIR/Scripts/build_app.sh"

rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR"
cp -R "$APP_DIR" "$STAGING_DIR/"
ln -s /Applications "$STAGING_DIR/Applications"

rm -f "$DMG_PATH"
hdiutil create \
  -volname "Transcript Pipeline" \
  -srcfolder "$STAGING_DIR" \
  -ov \
  -format UDZO \
  "$DMG_PATH"

rm -rf "$STAGING_DIR"
echo "$DMG_PATH"
