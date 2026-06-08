#!/bin/bash
set -euo pipefail

APP_NAME="SignalLight"
PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$HOME/Applications/${APP_NAME}.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

cd "$PROJECT_DIR"
swift build

mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
cp "$PROJECT_DIR/.build/debug/${APP_NAME}" "$MACOS_DIR/${APP_NAME}"
cp "$PROJECT_DIR/Info.plist" "$CONTENTS_DIR/Info.plist"

if [ -f "$HOME/Applications/${APP_NAME}.app/Contents/Resources/AppIcon.icns" ]; then
  :
fi

codesign --force --sign - "$APP_DIR"
