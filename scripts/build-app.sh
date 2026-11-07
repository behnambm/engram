#!/usr/bin/env bash
# Build the Swift package and assemble a real .app bundle around the binary.
# A bundle is required for LSUIElement (no Dock icon) to take effect.
#
# Usage: scripts/build-app.sh [debug|release]
set -euo pipefail

CONFIG="${1:-debug}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Engram"
APP="$ROOT/build/$APP_NAME.app"

# Date-formatted version, injected by CI. `VERSION` is what the user sees
# (e.g. 2026.11.07); `BUILD` is a unique timestamp. Both default to the checked-in values.
VERSION="${VERSION:-0.1.0}"
BUILD="${BUILD:-1}"

BIN_DIR="$(swift build -c "$CONFIG" --package-path "$ROOT" --show-bin-path)"
swift build -c "$CONFIG" --package-path "$ROOT"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
cp "$ROOT/Support/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Support/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$APP/Contents/Info.plist"
codesign --force --sign - "$APP" >/dev/null 2>&1

echo "built $APP ($VERSION / $BUILD)"
