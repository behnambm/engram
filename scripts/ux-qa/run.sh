#!/usr/bin/env bash
# Functional test harness for Engram's data layer (ClipStore + Settings + HotKeyCombo).
# Compiles the real sources together with Tests.swift and runs them against an ISOLATED
# HOME so the user's real clipboard DB is never touched.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

swiftc -parse-as-library \
  -module-cache-path "$WORK/mcache" \
  "$ROOT/Sources/Engram/ClipStore.swift" \
  "$ROOT/Sources/Engram/ClipboardWatcher.swift" \
  "$ROOT/Sources/Engram/Settings.swift" \
  "$ROOT/scripts/ux-qa/Tests.swift" \
  -o "$WORK/tests"

# Isolate UserDefaults + Application Support into a temp home. `HOME` alone is NOT
# enough: on macOS `URL.applicationSupportDirectory` ignores $HOME. `CFFIXED_USER_HOME`
# is what CoreFoundation actually honors, so it redirects both the DB and UserDefaults.
CFFIXED_USER_HOME="$WORK/home" "$WORK/tests"
