# siaheh

A macOS clipboard manager: a CopyClip-class menu-bar app with **search and filtering that stays
instant as history grows**. Currently: research + a working app shell.

| File | What it is |
|---|---|
| `Sources/Siaheh/main.swift` | The app: a paperclip in the menu bar. Right-click it for **Settings** and **Quit**. |
| `Sources/Siaheh/SettingsWindow.swift` | The Settings window, created once and reused. Holds the launch-at-login checkbox. |
| `Sources/Siaheh/LaunchAtLogin.swift` | Login-item state via `SMAppService` (the system owns it, not UserDefaults). |
| `Package.swift` | Swift package (Swift 6, macOS 14+). No dependencies. |
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
```

The app has no window and no Dock icon — only a paperclip in the menu bar. Right-click it and choose
**Settings** or **Quit**, or stop it from the shell:

```sh
pkill -f Siaheh.app
```

`Package.swift` also opens directly in Xcode, but run the built `.app` (not the bare binary) when you
care about bundle behaviour.

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
