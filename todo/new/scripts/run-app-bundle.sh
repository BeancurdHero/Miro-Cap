#!/bin/zsh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="ScreenMaskRecorder"
BUILD_DIR="$ROOT_DIR/.build"
EXECUTABLE_PATH="$BUILD_DIR/debug/$APP_NAME"
APP_BUNDLE_PATH="$BUILD_DIR/$APP_NAME.app"
CONTENTS_PATH="$APP_BUNDLE_PATH/Contents"
MACOS_PATH="$CONTENTS_PATH/MacOS"
RESOURCES_PATH="$CONTENTS_PATH/Resources"

"$ROOT_DIR/scripts/build-local.sh"

rm -rf "$APP_BUNDLE_PATH"
mkdir -p "$MACOS_PATH" "$RESOURCES_PATH"

cp "$EXECUTABLE_PATH" "$MACOS_PATH/$APP_NAME"
cp "$ROOT_DIR/ScreenMaskRecorder/Info.plist" "$CONTENTS_PATH/Info.plist"

if [ -d "$ROOT_DIR/ScreenMaskRecorder/Resources" ]; then
  cp -R "$ROOT_DIR/ScreenMaskRecorder/Resources/." "$RESOURCES_PATH/"
fi

chmod +x "$MACOS_PATH/$APP_NAME"
codesign --force --deep --sign - "$APP_BUNDLE_PATH"

open "$APP_BUNDLE_PATH"
