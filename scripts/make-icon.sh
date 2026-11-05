#!/usr/bin/env bash
# Regenerates Support/AppIcon.icns from the Swift drawing in make-icon.swift.
# Requires the macOS SDK (swiftc) and iconutil — both ship with Xcode.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

swiftc -O -module-cache-path "$WORK/mcache" "$ROOT/scripts/make-icon.swift" -o "$WORK/make-icon" >/dev/null
"$WORK/make-icon" "$WORK/AppIcon-1024.png"

ICONSET="$WORK/AppIcon.iconset"
mkdir -p "$ICONSET"

# iconutil requires the full set of sizes; generate them from the 1024 master.
for s in 16 32 128 256 512; do
  sips -z "$s" "$s" "$WORK/AppIcon-1024.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
done
for s in 32 64 256 512; do
  sips -z "$s" "$s" "$WORK/AppIcon-1024.png" --out "$ICONSET/icon_$((s/2))x$((s/2))@2x.png" >/dev/null
done
sips -z 1024 1024 "$WORK/AppIcon-1024.png" --out "$ICONSET/icon_512x512@2x.png" >/dev/null

iconutil -c icns "$ICONSET" -o "$ROOT/Support/AppIcon.icns"
cp "$WORK/AppIcon-1024.png" "$ROOT/Support/AppIcon-1024.png"
echo "wrote Support/AppIcon.icns"
