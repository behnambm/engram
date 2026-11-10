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

# Assemble and sign into a unique staging bundle, then swap it into place only after
# every step succeeds, so a failed build never destroys the last working bundle.
mkdir -p "$ROOT/build"
STAGING_DIR="$(mktemp -d "$ROOT/build/.Engram.staging.XXXXXX")"
trap 'rm -rf "$STAGING_DIR"' EXIT
STAGING="$STAGING_DIR/$APP_NAME.app"

mkdir -p "$STAGING/Contents/MacOS" "$STAGING/Contents/Resources"
cp "$BIN_DIR/$APP_NAME" "$STAGING/Contents/MacOS/$APP_NAME"
cp "$ROOT/Support/Info.plist" "$STAGING/Contents/Info.plist"
cp "$ROOT/Support/AppIcon.icns" "$STAGING/Contents/Resources/AppIcon.icns"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$STAGING/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$STAGING/Contents/Info.plist"
codesign --force --sign - "$STAGING" >/dev/null

rm -rf "$APP"
mv "$STAGING" "$APP"

echo "built $APP ($VERSION / $BUILD)"
