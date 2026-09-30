#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="${NOTCHWAVE_BUILD_DIR:-${TMPDIR:-/tmp}/notchwave-build}"
APP_PATH="${1:-$PROJECT_DIR/build/Notchwave.app}"
mkdir -p "$BUILD_DIR/module-cache" "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"
/usr/bin/xcrun swiftc -swift-version 5 -O -target arm64-apple-macosx13.0 \
  -sdk "${NOTCHWAVE_SDK_PATH:-$(/usr/bin/xcrun --show-sdk-path)}" \
  -module-cache-path "$BUILD_DIR/module-cache" \
  "$PROJECT_DIR"/Sources/Notchwave/*.swift \
  -o "$APP_PATH/Contents/MacOS/Notchwave"
/bin/cp "$PROJECT_DIR/Info.plist" "$APP_PATH/Contents/Info.plist"
/bin/cp "$PROJECT_DIR/Resources/remote-claude.py" "$APP_PATH/Contents/Resources/remote-claude.py"
/bin/cp "$PROJECT_DIR/Resources/claude-usage.py" "$APP_PATH/Contents/Resources/claude-usage.py"
/usr/bin/codesign --force --sign - --identifier app.notchwave.player "$APP_PATH"
echo "Built: $APP_PATH"
