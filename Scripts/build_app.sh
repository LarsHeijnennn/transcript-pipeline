#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
APP_DIR="$PROJECT_DIR/Release/Transcript Pipeline.app"
CONTENTS_DIR="$APP_DIR/Contents"

if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode-beta.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
fi

cd "$PROJECT_DIR"
swift build -c release --product TranscriptPipelineApp

rm -rf "$APP_DIR"
mkdir -p "$CONTENTS_DIR/MacOS" "$CONTENTS_DIR/Resources"
cp ".build/release/TranscriptPipelineApp" "$CONTENTS_DIR/MacOS/TranscriptPipelineApp"
cp "Configuration/Info.plist" "$CONTENTS_DIR/Info.plist"
chmod 755 "$CONTENTS_DIR/MacOS/TranscriptPipelineApp"

# Ad-hoc signing preserves sandbox entitlements. This is not Developer ID signing or notarization.
codesign --force --deep --sign - \
  --entitlements "Configuration/TranscriptPipeline.entitlements" \
  "$APP_DIR"

codesign --verify --deep --strict --verbose=2 "$APP_DIR"
echo "$APP_DIR"
