#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$PROJECT_DIR/../../work/build"
APP_DIR="${LISTENFLOW_APP_DIR:-$PROJECT_DIR/../听流.app}"
mkdir -p "$BUILD_DIR" "$(dirname "$APP_DIR")"
swiftc -swift-version 5 -O -parse-as-library -target arm64-apple-macosx15.0 \
  "$PROJECT_DIR"/Sources/*.swift -o "$BUILD_DIR/ListenFlow" \
  -framework SwiftUI -framework AppKit -framework ScreenCaptureKit \
  -framework AVFoundation -framework CoreMedia -framework Security -framework IOKit
# The `lstf` command line tool: lets an agent read transcripts. It shares the
# storage code with the app and ships inside the bundle.
swiftc -swift-version 5 -O -target arm64-apple-macosx15.0 \
  "$PROJECT_DIR"/Sources/{AudioChunker,Storage,ImageAttachments,Recognition,VolcProtocol,VolcFile,AgentBridge}.swift \
  "$PROJECT_DIR"/CLI/*.swift -o "$BUILD_DIR/lstf" -framework Security -framework IOKit

# Assemble and sign a complete bundle elsewhere, then swap it in by rename. Copying
# over the executable of a running app rewrites pages it has mapped, and macOS
# kills a process whose signed code changes underneath it; a renamed-away bundle
# keeps running on its old files until the user relaunches.
STAGE_ROOT="$(mktemp -d "$BUILD_DIR/stage.XXXXXX")"
STAGE="$STAGE_ROOT/$(basename "$APP_DIR")"
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources"
cp "$BUILD_DIR/ListenFlow" "$STAGE/Contents/MacOS/ListenFlow"
cp "$BUILD_DIR/lstf" "$STAGE/Contents/MacOS/lstf"
cp "$PROJECT_DIR/Backend/asr_worker.py" "$STAGE/Contents/Resources/"
cp "$PROJECT_DIR/Assets/AppIcon.icns" "$STAGE/Contents/Resources/AppIcon.icns"
cp "$PROJECT_DIR/Info.plist" "$STAGE/Contents/Info.plist"
if [ -n "${LISTENFLOW_BUNDLE_ID:-}" ]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $LISTENFLOW_BUNDLE_ID" "$STAGE/Contents/Info.plist"
fi
xattr -cr "$STAGE"
codesign --force --deep --sign - --identifier "${LISTENFLOW_BUNDLE_ID:-local.ListenFlow}" "$STAGE"
if [ -e "$APP_DIR" ]; then
  OLD="$STAGE_ROOT/previous.app"
  mv "$APP_DIR" "$OLD"
  mv "$STAGE" "$APP_DIR"
else
  mv "$STAGE" "$APP_DIR"
fi
rm -rf "$STAGE_ROOT"
# Only the real app belongs in Spotlight/Launchpad; preview and test builds would
# otherwise pile up as extra 「听流」 entries.
if [ -z "${LISTENFLOW_BUNDLE_ID:-}" ]; then
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP_DIR" 2>/dev/null || true
  # Put `lstf` on the PATH when the usual per-user place for that exists.
  LSTF="$(cd "$(dirname "$APP_DIR")" && pwd)/$(basename "$APP_DIR")/Contents/MacOS/lstf"
  if [ -d "$HOME/.local/bin" ]; then
    ln -sf "$LSTF" "$HOME/.local/bin/lstf"
    printf 'Linked: %s -> %s\n' "$HOME/.local/bin/lstf" "$LSTF"
  else
    printf 'To use the command line tool: ln -s "%s" <a folder on your PATH>/lstf\n' "$LSTF"
  fi
fi
printf 'Built: %s\n' "$APP_DIR"
