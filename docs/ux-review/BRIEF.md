# Engram UI/UX test & refine — shared brief

## What Engram is
A native macOS menu-bar clipboard manager. Copy text → it is recorded into a local
SQLite DB → press ⌥⌘V to open a searchable history window → type to search, ↑↓ to
choose, Enter to paste, Esc to close. Settings reachable via right-click on the menu-bar
brain icon. Landing page at `site/index.html`.

## Project map
- `Sources/Engram/HistoryWindow.swift` — the history window (main UI). Pure AppKit,
  custom dark-indigo palette (`Palette` enum, `fileprivate`), custom selected-row pill,
  compact single-line rows with source + relative timestamp.
- `Sources/Engram/SettingsWindow.swift` — settings window (System-Settings-style form rows).
- `Sources/Engram/Settings.swift` — `UserDefaults`-backed prefs + `HotKeyCombo`.
- `Sources/Engram/main.swift` — menu-bar agent, status item, global hotkey, status-item
  position (right-edge) logic.
- `Sources/Engram/ClipStore.swift` — SQLite + FTS5 search, preview truncation, retention.
- `Sources/Engram/ClipboardWatcher.swift` — 500 ms pasteboard poll + ignored-types list.
- `site/index.html` — Apple-style landing page (CSS-only, light/dark, responsive).
- `scripts/build-app.sh` — builds `build/Engram.app`.

## Current state: in-progress dark-indigo redesign (do NOT clobber)
The working tree has an uncommitted redesign of the history window (dark opaque
indigo palette, rounded search container, custom title label, compact rows). Build ON
it, refine it. Do not revert it to the older translucent material design.

## Live-test recipe (app runs on this real Mac)
```bash
./scripts/build-app.sh debug            # build build/Engram.app
ENGRAM_DEBUG_WINDOW=history open build/Engram.app   # opens history window on launch
ENGRAM_DEBUG_WINDOW=settings open build/Engram.app  # opens settings window on launch
pkill -x Engram                         # quit when done
```
`ENGRAM_DEBUG_WINDOW` is a TEMPORARY hook the lead added to `main.swift`
(`applicationDidFinishLaunching`). Leave it alone; the lead will revert it at the end.

Verify a window is on screen (no image model available — check geometry/title only):
`swiftc -o /tmp/list_windows /tmp/list_windows.swift` if the helper exists, else use
`CGWindowListCopyWindowInfo` with `optionOnScreenOnly` filtering owner "Engram".

Real clip DB (do not mutate outside a temp HOME): `~/Library/Application Support/Engram/history.sqlite`
(~150 real clips, mixed English/Persian, paths, code, URLs).

## SAFETY — read this first (a real data-loss incident already happened)
The lead's first functional harness ran `enforceRetention()` while incorrectly isolated
(used `HOME=`, which macOS `URL.applicationSupportDirectory` IGNORES), trimming the real
clipboard history from 150 → 6 clips. Recovery was partial. **Do not repeat this.**

Rules:
- NEVER run `enforceRetention()` / `deleteAll()` / any `DELETE` against the real DB at
  `~/Library/Application Support/Engram/history.sqlite`.
- The functional harness (`scripts/ux-qa/run.sh`) is now isolated with
  `CFFIXED_USER_HOME` — the ONLY env var CoreFoundation honors to redirect BOTH
  `applicationSupportDirectory` and `UserDefaults`. If you write any other test/script
  that opens a `ClipStore`, isolate it the same way. `HOME=` is NOT sufficient on macOS.
- Launching the app (`ENGRAM_DEBUG_WINDOW=... open build/Engram.app`) is fine: the app
  only reads + appends real copies (normal clipboard-manager behavior). Just never trim.

## Critical constraint
The ONLY model available is `deepseek-v4-pro`, which does NOT accept image input.
No one on the team can "see" a screenshot. Therefore:
- Test UI/UX via CODE review, layout/constraint analysis, and NUMERIC checks
  (contrast ratios, sizes, spacing, keyboard event handling).
- Do not rely on screenshots; do not ask to read PNGs.

## WCAG contrast — already computed by the lead (use these, do not re-derive)
All ratios are luminance-contrast (WCAG 2.x). Normal text needs ≥ 4.5:1; large text
(≥18pt/14pt-bold) and UI components need ≥ 3:1.

App palette (`HistoryWindow.Palette`, calibrated 0–1 → 8-bit):
- background (0.086,0.090,0.184) = #16172F
- primaryText (0.941,0.941,0.969) = #F0F0F7
- secondaryText (0.467,0.471,0.549) = #77788C
- searchBackground (0.133,0.141,0.235) = #22243C
- searchBorder (0.239,0.247,0.357)
- selectedRow (0.145,0.176,0.353) = #252D5A

App results:
- primaryText on background = 15.46:1 (PASS)
- secondaryText on background = **4.05:1 (FAIL for normal text)** — used by titleLabel
  (16pt), statusLabel (13pt "N clips"), emptyLabel (14pt), and timeLabel when unselected
- secondaryText on searchBackground = 3.50:1 (FAIL)
- searchBorder on background = 1.72:1 (FAIL as a component boundary vs adjacent bg)
- primaryText on selectedRow = 11.56:1 (PASS)

Site tokens:
- Light `--text-tertiary #86868b` on `--bg #fbfbfd` = **3.51:1 (FAIL)** — used for
  `.window-title` (12px), `.mock-meta` (11px), `.window-status` (11px), `.hint`, footer.
- Light `--text-secondary #6e6e73` on bg = 4.91:1 (PASS).
- Light button white-on-`--accent #5867e8` = 4.65:1 (PASS).
- Dark `--text-tertiary #71717a` on `--bg #0a0c1c` = **4.01:1 (FAIL)**.
- Dark button white-on-`--accent #6b79f0` = **3.74:1 (FAIL)** (16px text is NOT "large").

## Known product/design mismatch (high-value fix)
The landing page's CSS "product mock" (`site/index.html` `.window`, `.mock-row.selected`
= `--accent-soft`, light card) still shows the OLD light translucent design. The real app
is now a dark-indigo opaque window with `selectedRow #252D5A` selection and a bordered
dark search field. The mock should be updated to match the new product so the marketing
page is honest.

## Team write scopes (advisory, do not overlap)
- `app-ux` owns `Sources/Engram/`
- `web-ux` owns `site/`
- `functional-qa` owns `scripts/ux-qa/` and writes `docs/ux-review/functional.md`

## Deliverable format
Each teammate: (1) make the code changes in its own scope; (2) build/verify what it
changed; (3) write a short report into `docs/ux-review/<name>.md` listing: findings →
what changed → before/after (numeric where possible) → any items deferred (and why).
The lead will review the full diff, run `./scripts/build-app.sh debug`, run the
functional harness, and revert the temporary debug hook.
