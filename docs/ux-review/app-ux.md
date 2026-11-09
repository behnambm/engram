# app-ux — Engram native AppKit UI review & refine

Scope: `Sources/Engram/` only. Builds on the in-progress dark-indigo redesign; nothing reverted.

## What changed (summary)

| # | Task | Decision | Files |
|---|------|----------|-------|
| 1 | WCAG contrast failures | Raised `secondaryText`, brightened `searchBackground` + `searchBorder` | `HistoryWindow.swift` |
| 2 | Search-field sanity | Replaced `NSSearchField` with a plain `NSTextField` | `HistoryWindow.swift` |
| 3 | Appearance consistency | Forced `.darkAqua` on Settings (smallest coherent fix) | `SettingsWindow.swift` |
| 4 | Status label during search | Show "N of T" while a query is active | `HistoryWindow.swift`, `ClipStore.swift` |
| 5 | Selected-row state | Dim the pill via `isEmphasized` when window not key | `HistoryWindow.swift` |
| 6 | Polish | `<60s` now "Ns"; Settings heading/spacing verified | `HistoryWindow.swift` |

---

## 1. WCAG contrast fixes — `HistoryWindow.Palette`

All ratios are luminance-contrast (WCAG 2.x). Normal text ≥ 4.5:1; UI component
boundaries ≥ 3:1. Background `#16172F` luminance 0.00985.

### secondaryText (title / status / empty / unselected time-meta)

| State | Color | Luminance | vs background | vs searchBackground |
|-------|-------|-----------|---------------|---------------------|
| Before | `#77788C` (0.467,0.471,0.549) | 0.193 | **4.06:1 FAIL** | 3.51:1 FAIL |
| After  | `#8F90A2` (0.56,0.565,0.635) | 0.284 | **5.58:1 PASS** | 4.12:1 |

Kept the cool-gray hue family; raised luminance to 0.284 (target ≥ 0.228). Now passes
for the 16pt title, 13pt status, 14pt empty label, and 14pt unselected time/meta text.
(`secondaryText` is not actually drawn on the search background — the field text is
`primaryText` — so the 4.12:1 there is informational only.)

### Search field boundary

| Pair | Before | After |
|------|--------|-------|
| searchBorder vs background | **1.72:1 FAIL** | **3.57:1 PASS** |
| searchBorder vs searchBackground | 1.49:1 | 2.63:1 |
| searchBackground vs background | 1.16:1 (subtle) | 1.35:1 |

- `searchBackground`: `#22243C` → `#2D2F4C` (0.176,0.184,0.298) — a modest lift so the
  field reads as a distinct filled surface without going light.
- `searchBorder`: `(0.239,0.247,0.357)` → `#6B6E94` (0.42,0.43,0.58) — now ≥3:1 against
  the surrounding window, the boundary the user keys on.

## 2. Search-field sanity → plain NSTextField

The container (`searchContainer`) already draws the rounded border, background, and
1.4px stroke. A bezelless `NSSearchField` still renders its internal magnifier icon and
the cancel (x) button, which fight the custom border: risk of a double edge and an
orphaned icon sitting next to a container border that looks like the field's own bezel.
There is no clean way to suppress the magnifier/cancel glyphs on `NSSearchField`.

Decision: simplify to a plain `NSTextField` (`isBezeled=false`, `isBordered=false`,
`drawsBackground=false`, `focusRingType=.none`, `usesSingleLineMode=true`) with the
placeholder "Search history". The container is now the single source of the field's
visual boundary — no artifacts possible.

Keyboard hook preserved: `control(_:textView:doCommandBy:)` is
`NSControlTextEditingDelegate`, inherited by `NSTextFieldDelegate`. The delegate
conformance changed from `NSSearchFieldDelegate` to `NSTextFieldDelegate`; the same
field editor drives it, so ↑/↓ move the list, Return copies, Esc closes. Single-line
mode guarantees Return arrives as `insertNewline:` (not a newline insertion).

## 3. Appearance consistency → force dark on Settings

History forces `.darkAqua` + opaque indigo. Settings was adaptive (`.popover`
material, `isOpaque=false`), so the two windows could disagree with the system theme.

Minimal coherent fix (chosen over making History adaptive, which would require an
adaptive palette): set `window?.appearance = NSAppearance(named: .darkAqua)` on
Settings. All Settings text uses system `labelColor` (heading + row labels) and system
controls (`NSSwitch`, `NSPopUpButton`, `NSButton`), which flip to their dark variants,
so they remain legible on the dark popover material. No explicit colors needed.

## 4. Status label during search

Before: `updateStatus()` always showed `store.count` ("1,234 clips") even while a query
filtered the list.

After: `reload()` passes the query; `updateStatus(for:)` shows:
- no query → `"1,234 clips"` (unchanged)
- query active → `"3 of 1,234"` (matches of total)

Added `ClipStore.matchCount(_:)`, which mirrors `search` (FTS5 count, then substring
fallback) so the reported number always agrees with the rows shown and is not capped by
the 200-row display limit. Empty state stays consistent: `0 of 1,234` in the status bar
and "No matches" in the list center.

## 5. Selected-row state when window not key

Before: `HistoryRowView.drawSelection` always painted full `selectedRow #252D5A`.

After: it keys off the row view's `isEmphasized` — the same AppKit signal the cell
already uses (`backgroundStyle == .emphasized`) — and paints
`selectedRow.withAlphaComponent(0.45)` when not emphasized. A non-key window keeps the
row selected but with a visibly dimmed pill, and the pill/text stay in sync.

## 6. Small polish

- `shortTimestamp`: `<60s` now returns `"\(seconds)s"` (e.g. "42s"), keeping `"now"`
  only for the sub-second boundary, instead of labeling everything under a minute
  "now".
- Settings heading: verified by layout analysis. Window uses `fullSizeContentView` +
  transparent titlebar + hidden title; the "Settings" heading is pinned at
  `top + 44` / `leading 20`, below the traffic-light row (which sits ≈ y 13–27), so it
  clears the close/minimize buttons (no zoom button in the mask).
- Row spacing: the form stack uses a uniform `spacing = 8` around `NSBox.separator`
  dividers (row → 8 → divider → 8 → row …), so rows are evenly spaced.

---

## Verification

`./scripts/build-app.sh debug` compiled clean ("Build complete!", no warnings).

Window-on-screen check via `CGWindowListCopyWindowInfo` (`/tmp/list_windows`,
`optionOnScreenOnly`, owner "Engram"):

- History: `pid=3813 owner=Engram name="Engram — Clipboard History" bounds 500×310 @ (506,175)`
- Settings: `pid=3878 owner=Engram name="Settings" bounds 460×320 @ (526,173)`

Both windows render at their configured sizes. `pkill -x Engram` run after each check.

(No image model is available, so "looks right" is verified by compile + geometry +
the contrast arithmetic above, per the brief.)

## Deferred / notes

- **Search placeholder color**: left at the system dark placeholder color. It is legible
  on `#2D2F4C`, but is not pinned to the palette. If strict palette ownership is wanted
  later, set `placeholderAttributedString` explicitly. Not done to keep the change
  minimal.
- **Settings row labels on `.popover` material**: system `labelColor` under forced
  darkAqua is white-ish and legible, but the exact tint depends on the material's
  translucency over whatever is behind the window. If a fully deterministic surface is
  ever wanted, Settings could adopt the history's opaque indigo — deliberately not done
  here (bigger change than "smallest coherent fix").
- **Landing-page mock mismatch** (`site/index.html`) is out of scope for `app-ux`; it is
  owned by `web-ux`.
