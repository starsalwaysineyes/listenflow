#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$PROJECT_DIR/../../work/build"
APP_DIR="${LISTENFLOW_APP_DIR:-$PROJECT_DIR/../听流.app}"
mkdir -p "$BUILD_DIR" "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
swiftc -swift-version 5 -O -parse-as-library -target arm64-apple-macosx15.0 \
  "$PROJECT_DIR"/Sources/*.swift -o "$BUILD_DIR/ListenFlow" \
  -framework SwiftUI -framework AppKit -framework ScreenCaptureKit \
  -framework AVFoundation -framework CoreMedia -framework Security
cp "$BUILD_DIR/ListenFlow" "$APP_DIR/Contents/MacOS/ListenFlow"
cp "$PROJECT_DIR/Backend/asr_worker.py" "$APP_DIR/Contents/Resources/"
cp "$PROJECT_DIR/Assets/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
cp "$PROJECT_DIR/Info.plist" "$APP_DIR/Contents/Info.plist"
if [ -n "${LISTENFLOW_BUNDLE_ID:-}" ]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $LISTENFLOW_BUNDLE_ID" "$APP_DIR/Contents/Info.plist"
fi
xattr -cr "$APP_DIR"
codesign --force --deep --sign - --identifier "${LISTENFLOW_BUNDLE_ID:-local.ListenFlow}" "$APP_DIR"
printf 'Built: %s\n' "$APP_DIR"
