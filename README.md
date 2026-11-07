# engram

<p align="center">
  <img src="Support/AppIcon-1024.png" alt="Engram" width="128" height="128">
</p>

<p align="center">
  <a href="https://behnambm.github.io/engram/">behnambm.github.io/engram</a>
</p>

A macOS clipboard manager. Copy as usual — search and paste anything you've copied, instantly.

## Use it

1. Copy things — text clips are saved automatically.
2. Press **⌥⌘V** to open history.
3. Type to search · **↑ ↓** to choose · **Enter** to paste (or click a clip).
4. **Esc** closes. Right-click the 🧠 for Settings and Quit.

## Install

- **Download:** [latest release](https://github.com/behnambm/engram/releases/latest)
- **From source:** `./scripts/build-app.sh` then `open build/Engram.app`

## Why it's fast

One SQLite database is the only source of truth. FTS5 ordered by `rowid DESC` (never `rank`) stays sub-millisecond at 100k clips — no in-memory mirror. Everything stays on your Mac.

Deep dive: [`docs/clipboard-manager-research.md`](docs/clipboard-manager-research.md)
