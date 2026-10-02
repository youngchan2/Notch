#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="${NOTCHWAVE_BUILD_DIR:-$PROJECT_DIR/.build}"
SDK_PATH="${NOTCHWAVE_SDK_PATH:-$(/usr/bin/xcrun --show-sdk-path)}"
mkdir -p "$BUILD_DIR/module-cache"

# Compile checks against the same sources without starting the app or its services.
/usr/bin/xcrun swiftc -swift-version 5 -D NOTCHWAVE_CHECKS -target arm64-apple-macosx13.0 \
  -sdk "$SDK_PATH" -module-cache-path "$BUILD_DIR/module-cache" \
  "$PROJECT_DIR"/Sources/Notchwave/*.swift "$PROJECT_DIR"/Tests/Swift/*.swift \
  -o "$BUILD_DIR/NotchwaveChecks"
"$BUILD_DIR/NotchwaveChecks"
python3 -B -m unittest discover -s "$PROJECT_DIR/Tests" -v
