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

if [[ -n "${DEVELOPER_ID_APPLICATION:-}" ]]; then
  codesign --force --deep \
    --sign "$DEVELOPER_ID_APPLICATION" \
    --options runtime \
    --timestamp \
    --entitlements "Configuration/TranscriptPipeline.entitlements" \
    "$APP_DIR"
else
  # Developer builds remain ad-hoc signed so sandbox entitlements work locally.
  codesign --force --deep --sign - \
    --entitlements "Configuration/TranscriptPipeline.entitlements" \
    "$APP_DIR"
fi

codesign --verify --deep --strict --verbose=2 "$APP_DIR"
if [[ -n "${DEVELOPER_ID_APPLICATION:-}" ]]; then
  codesign -dv --verbose=4 "$APP_DIR"
fi
echo "$APP_DIR"
