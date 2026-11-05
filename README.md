# siaheh

A macOS clipboard manager: a CopyClip-class menu-bar app with **search and filtering that stays
instant as history grows**.

## Using it

1. Copy things as usual — text clips are recorded automatically.
2. Press **⌥⌘V** (the global shortcut) to open the history window in the centre of the screen.
3. Move with **↑ ↓**, then **Enter** to copy the selected clip and close the window — or just click a
   clip to copy it and close.
4. **Esc** closes without copying.
5. Right-click the paperclip for **Clipboard History**, **Settings** and **Quit**.

Settings holds the history retention limit (default **No limit**), the shortcut recorder, and
start-at-login.

| File | What it is |
|---|---|
| `Sources/Siaheh/main.swift` | Menu-bar agent: status item, menu, and wiring of store/watcher/hotkey/windows. |
| `Sources/Siaheh/ClipStore.swift` | SQLite history. `id` is the rowid, so newest-first is `ORDER BY id DESC` — no sort, no timestamp index. |
| `Sources/Siaheh/ClipboardWatcher.swift` | Polls `changeCount` every 500 ms; skips concealed/transient/password-manager pasteboard types. |
| `Sources/Siaheh/HistoryWindow.swift` | The centered list window: arrows, Return, click-to-copy, closes on copy. |
| `Sources/Siaheh/HotKey.swift` | Carbon `RegisterEventHotKey` — a global shortcut with no Accessibility permission. |
| `Sources/Siaheh/Settings.swift` | `UserDefaults`-backed preferences. Launch-at-login is *not* here (the system owns it). |
| `Sources/Siaheh/SettingsWindow.swift` | Settings window plus the shortcut recorder button. |
| `Sources/Siaheh/LaunchAtLogin.swift` | Login-item state via `SMAppService`. |
| `Package.swift` | Swift package (Swift 6, macOS 14+). No dependencies; uses the system SQLite. |
| `Support/Info.plist` | Bundle metadata. `LSUIElement` = no Dock icon, no app switcher entry. |
| `scripts/build-app.sh` | Builds the package and assembles `build/Siaheh.app` (a bundle is required for `LSUIElement`). |
| `docs/clipboard-manager-research.md` | The decision document: market, platform constraints, measured benchmarks, architecture, feature spec, build plan. **Start here.** |
| `docs/storage-research.md` | Storage/search appendix: validated DDL, every FTS5 failure mode reproduced, library comparison. |
| `docs/market-teardown.md` | Product-by-product teardown with evidence tags (verified / unverified). |
| `benchmarks/` | Reproducible FTS5 and in-memory scan benchmarks with latency budgets. |

## Build and run

```sh
./scripts/build-app.sh          # debug
./scripts/build-app.sh release  # release
open build/Siaheh.app
pkill -f Siaheh.app             # stop it
```

`Package.swift` also opens directly in Xcode, but launch the built `.app` (not the bare binary) when
behaviour depends on the bundle: `LSUIElement`, the login item, and the app's TCC identity.

History lives at `~/Library/Application Support/Siaheh/history.sqlite` (WAL mode). Delete the folder
to reset it.

## Not built yet

Search, filtering by source app or content type, pinning/snippets, plain-text paste, images, and
auto-paste. Also: no pause-recording toggle, and the "no limit" retention means the database grows
until you pick a limit.

## Research verdict, in one line

The "slow when history grows" problem is a data-layout problem, not a search problem. Ordering FTS5
results by `rowid DESC` (never `rank`, never a joined column) makes a 100k-clip search cost
0.03–2 ms instead of 12–25 ms, so a single SQLite database can be the only source of truth — no
in-memory mirror of history.

Numbers were measured on macOS 27.0.1 / Apple Silicon / SQLite 3.54.0. Reproduce:

```sh
python3 benchmarks/fts5_bench.py
swiftc -O benchmarks/memscan_bench.swift -o /tmp/memscan && /tmp/memscan
```
