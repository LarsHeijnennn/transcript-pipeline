#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
APP_DIR="$PROJECT_DIR/Release/What Was Said.app"
DMG_PATH="$PROJECT_DIR/Release/What-Was-Said.dmg"
ZIP_PATH="$PROJECT_DIR/Release/What-Was-Said-notarization.zip"

if [[ -z "${DEVELOPER_ID_APPLICATION:-}" ]]; then
  echo "Set DEVELOPER_ID_APPLICATION to the exact Developer ID Application certificate name." >&2
  exit 2
fi
if [[ -z "${NOTARY_PROFILE:-}" ]]; then
  echo "Set NOTARY_PROFILE to an xcrun notarytool Keychain profile." >&2
  exit 2
fi

"$PROJECT_DIR/Scripts/build_app.sh"
rm -f "$ZIP_PATH"
ditto -c -k --keepParent "$APP_DIR" "$ZIP_PATH"
xcrun notarytool submit "$ZIP_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP_DIR"
xcrun stapler validate "$APP_DIR"

SKIP_BUILD=1 "$PROJECT_DIR/Scripts/create_dmg.sh"
xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG_PATH"
xcrun stapler validate "$DMG_PATH"
spctl --assess --type execute --verbose=4 "$APP_DIR"
spctl --assess --type open --context context:primary-signature --verbose=4 "$DMG_PATH"
shasum -a 256 "$DMG_PATH"
rm -f "$ZIP_PATH"
echo "$DMG_PATH"
