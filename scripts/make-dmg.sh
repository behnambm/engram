#!/usr/bin/env bash
# Builds a release .app and packages it as a styled .dmg (custom background, icon
# layout, and window). Requires Xcode tools and python3 with `dmgbuild`
# (`pip3 install dmgbuild`).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# 1. Release app (AppIcon.icns included by build-app.sh)
"$ROOT/scripts/build-app.sh" release

# 2. Background image
swiftc -O -module-cache-path "$WORK/mcache" "$ROOT/scripts/make-background.swift" -o "$WORK/make-background" >/dev/null
"$WORK/make-background" "$WORK/background.png"

# 3. Stage the volume contents
STAGE="$WORK/stage"
mkdir -p "$ROOT/dist" "$STAGE"
cp -R "$ROOT/build/Engram.app" "$STAGE/"
cp "$WORK/background.png" "$STAGE/background.png"

cat > "$STAGE/settings.py" <<'PY'
import os
format = "UDZO"
files = [os.path.join(os.getcwd(), "Engram.app")]
symlinks = {"Applications": "/Applications"}
background = "background.png"
icon_locations = {"Engram.app": (150, 205), "Applications": (430, 205)}
window_rect = ((120, 120), (660, 400))
default_view = "icon-view"
show_icon_preview = False
show_item_info = False
icon_size = 96
text_size = 12
label_pos = "bottom"
arrange_by = None
grid_offset = (0, 0)
grid_spacing = 100
scroll_position = (0, 0)
show_sidebar = False
show_toolbar = False
show_status_bar = False
show_pathbar = False
PY

# 4. Build the disk image
(cd "$STAGE" && python3 -m dmgbuild -s settings.py "Engram" "$ROOT/dist/Engram.dmg")
echo "wrote $ROOT/dist/Engram.dmg"
