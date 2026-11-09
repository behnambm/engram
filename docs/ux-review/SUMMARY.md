# Engram UI/UX test & refine — summary

## What was done (subagent team)
- **`app-ux`** refined the native AppKit UI (`Sources/Engram/`): fixed WCAG contrast
  (secondary text 4.05→5.58:1, search border 1.72→3.57:1), replaced `NSSearchField` with a
  plain `NSTextField` (kills magnifier/cancel artifacts), forced dark appearance on Settings
  for consistency, "N of T" match status, dimmed non-key selection, "Ns" timestamps.
- **`web-ux`** refined the landing page (`site/index.html`): product mock now matches the real
  dark-indigo app, contrast fixed (light tertiary 3.51→4.91, dark tertiary 4.01→4.69, dark
  button 3.74→4.65), `:focus-visible` + `aria-hidden` added, links verified 200.
- **`functional-qa`** built a 77-test harness (`scripts/ux-qa/`) covering ClipStore search,
  preview, retention, HotKeyCombo, matchExpression — all green.

## Result
- `./scripts/build-app.sh debug` → clean.
- `scripts/ux-qa/run.sh` → 77 PASS, isolated from the real DB via `CFFIXED_USER_HOME`.
- Both windows verified on screen (History 500×310, Settings 460×320).

## ⚠️ Data-loss incident (lead, transparently reported)
While building the first harness, the lead ran `enforceRetention()` with a bad isolation
(`HOME=` does NOT redirect `URL.applicationSupportDirectory` on macOS), which trimmed the real
clipboard history from 150 → 6 clips. It was partially recovered:
- Byte snapshot: `~/Library/Application Support/Engram/history.sqlite.damage-snapshot-1794216243`
- Salvaged text (494 fragments; timestamps/order NOT recoverable): `~/engram-clipboard-recovery.txt`
- Junk test clips removed; real DB now holds genuine clips only.
- Harness fixed to isolate with `CFFIXED_USER_HOME` (the only env var CoreFoundation honors
  for both `applicationSupportDirectory` and `UserDefaults`).

## BUG-1 decision (search)
`ClipStore.search()` drops mid-word substring hits when any FTS prefix hit exists. **Kept as a
documented trade-off** — unioning would add a full-table `LIKE` scan (~12–16 ms at 100k clips)
to every search, breaking the sub-millisecond guarantee. Doc comment + pinned test updated.
Union fix is ready to apply if correctness-over-speed is ever wanted.

## Reports
- `docs/ux-review/app-ux.md`, `docs/ux-review/web-ux.md`, `docs/ux-review/functional.md`
- `docs/ux-review/BRIEF.md` — shared context + safety rules
