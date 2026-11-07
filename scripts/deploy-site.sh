#!/usr/bin/env bash
# Publishes the landing page in site/ to https://behnambm.github.io/engram/.
# The page lives in the behnambm.github.io user-site repo, under engram/.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO="git@github.com:behnambm/behnambm.github.io.git"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

git clone -q "$REPO" "$WORK"
mkdir -p "$WORK/engram"

cp "$ROOT/site/index.html" "$WORK/engram/index.html"
cp "$ROOT/Support/AppIcon-1024.png" "$WORK/engram/icon.png"
[ -f "$ROOT/dist/Engram.dmg" ] && cp "$ROOT/dist/Engram.dmg" "$WORK/engram/Engram.dmg"

git -C "$WORK" add engram
if git -C "$WORK" diff --cached --quiet; then
  echo "nothing to deploy (no changes)"
  exit 0
fi

git -C "$WORK" commit -q -m "feat(engram): update landing page"
git -C "$WORK" push -q origin master
echo "deployed https://behnambm.github.io/engram/"
