#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
APP_DIR="$PROJECT_DIR/Release/What Was Said.app"
if [[ -n "${DEVELOPER_ID_APPLICATION:-}" ]]; then
  DMG_PATH="$PROJECT_DIR/Release/What-Was-Said.dmg"
else
  DMG_PATH="$PROJECT_DIR/Release/What-Was-Said-unsigned.dmg"
fi
STAGING_DIR="$PROJECT_DIR/Release/dmg-staging"

if [[ "${SKIP_BUILD:-0}" != "1" ]]; then
  "$PROJECT_DIR/Scripts/build_app.sh"
fi

rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR"
cp -R "$APP_DIR" "$STAGING_DIR/"
ln -s /Applications "$STAGING_DIR/Applications"

rm -f "$DMG_PATH"
diskutil image create from \
  --volumeName "What Was Said" \
  --format UDZO \
  "$STAGING_DIR" \
  "$DMG_PATH"

hdiutil verify "$DMG_PATH"

rm -rf "$STAGING_DIR"
echo "$DMG_PATH"
