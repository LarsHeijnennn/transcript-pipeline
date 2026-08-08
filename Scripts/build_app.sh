#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
APP_DIR="$PROJECT_DIR/Release/What Was Said.app"
CONTENTS_DIR="$APP_DIR/Contents"
ICON_SOURCE="$PROJECT_DIR/Assets/WhatWasSaid-logo-concept.png"

if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode-beta.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
fi

cd "$PROJECT_DIR"
swift build -c release --product TranscriptPipelineApp

if [[ ! -f "$ICON_SOURCE" ]]; then
  echo "Missing app icon source: $ICON_SOURCE" >&2
  exit 1
fi

ICON_WORK_DIR="$(mktemp -d -t what-was-said-icon)"
ICONSET_DIR="$ICON_WORK_DIR/WhatWasSaid.iconset"
trap 'rm -rf "$ICON_WORK_DIR"' EXIT
mkdir -p "$ICONSET_DIR"

for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$ICON_SOURCE" --out "$ICONSET_DIR/icon_${size}x${size}.png" >/dev/null
  doubled=$((size * 2))
  sips -z "$doubled" "$doubled" "$ICON_SOURCE" --out "$ICONSET_DIR/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET_DIR" -o "$ICON_WORK_DIR/WhatWasSaid.icns"

rm -rf "$APP_DIR"
mkdir -p "$CONTENTS_DIR/MacOS" "$CONTENTS_DIR/Resources"
cp ".build/release/TranscriptPipelineApp" "$CONTENTS_DIR/MacOS/TranscriptPipelineApp"
cp "Configuration/Info.plist" "$CONTENTS_DIR/Info.plist"
cp "$ICON_WORK_DIR/WhatWasSaid.icns" "$CONTENTS_DIR/Resources/WhatWasSaid.icns"
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
