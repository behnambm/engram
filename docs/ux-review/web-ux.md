# web-ux — Engram landing page report

Scope: `site/index.html` only. Contrast ratios below are WCAG 2.x luminance contrast
(recomputed with a local script; before-values match the BRIEF's lead-computed numbers).

---

## 1. Product mock now matches the real dark-indigo app

The `.window` mock previously drew the **old light translucent design**
(`background: var(--card)`, blur, `--accent-soft` selection). It now draws the real
`HistoryWindow.Palette` as an **always-dark, opaque** window in **both** light and dark
page modes.

- Added mock-only tokens scoped to `.window` (never follow the page theme):
  - `--mock-bg #16172F` · `--mock-text #F0F0F7` · `--mock-secondary #9A9DB3`
  - `--mock-search-bg #22243C` · `--mock-search-border #3D3F5B` · `--mock-selected #252D5A`
  - `--mock-divider #34354C` · `--mock-caret #7C88FF`
- `.window`: opaque `#16172F`, removed backdrop blur, subtle `#34354C` border, added a
  divider line under the titlebar (matches the real `divider` under the 46pt title bar).
- `.mock-search`: `#22243C` fill + `#3D3F5B` border (matches `searchBackground`/`searchBorder`).
- `.mock-row.selected`: `#252D5A` rounded pill (was `--accent-soft`).
- Rows are compact single-line with `app · time` meta (already present), text 13→14px,
  meta 11→12px, tightened padding.
- Removed `.window` from the `prefers-reduced-transparency` rule (it is no longer
  translucent; the old rule would have repainted it `var(--card-solid)`).

The mock's meta/title/status use `#9A9DB3`, which is lighter than the app's exact
`secondaryText #77788C` — see §2 note (the exact value fails at 11–12px).

---

## 2. WCAG contrast — before → after

| Element | Before | After | Result |
|---|---|---|---|
| Light `--text-tertiary` (`.hint`, footer, `.demo .mag`) on `#fbfbfd` | `#86868b` = **3.51:1** | `#6e6e73` = **4.91:1** | ✅ PASS |
| Dark `--text-tertiary` (same) on `#0a0c1c` | `#71717a` = **4.01:1** | `#7c7c85` = **4.69:1** | ✅ PASS |
| Button — dark base (white on fill) | `#6b79f0` = **3.74:1** | `#5867e8` = **4.65:1** | ✅ PASS |
| Button — hover (white on fill) | light `#6574f2` = **3.94:1** / dark `#7c88ff` = **3.08:1** | `#4c5ad1` = **5.69:1** | ✅ PASS |
| Button — active (white on fill) | light `#4c5ad1` = 5.69 / dark `#5867e8` = 4.65 | `#4350b8` = **6.82:1** | ✅ PASS |
| Mock primary text `#F0F0F7` on `#16172F` | — | **15.46:1** | ✅ PASS |
| Mock meta/title/status `#9A9DB3` on `#16172F` / `#252D5A` | (app `#77788C` = 4.05 / 3.03) | **6.55:1** / **4.90:1** | ✅ PASS |

### How the button was fixed
`--accent` now means "accent for text/links/focus" and a new set of fill tokens drives the
primary button: `--btn-bg #5867e8`, `--btn-bg-hover #4c5ad1`, `--btn-bg-press #4350b8`
(mode-independent, all ≥4.5 with white text). This is required because `#5867e8` as
*text* on the dark page is only 4.18:1 — so the button fill and the accent text color had
to be decoupled. `.btn`, `.btn:hover`, `.btn:active` now use `--btn-bg*`.
Removed the now-unused `--accent-hover` / `--accent-press`.

### Extra find (not in the BRIEF)
Light accent-as-text `#5867e8` on `#fbfbfd` (`.eyebrow` 12px, `.btn-ghost` 16px) is
**4.495:1** — a hair under 4.5. Darkened light `--accent` to `#5462dc` → **4.887:1** ✅.
Dark `--accent` stays `#6b79f0` (5.19:1 on `#0a0c1c`).

### Mock note (deferred, on purpose)
Mock search border `#3D3F5B` on `#16172F` = 1.72:1 and outer/divider `#34354C` = 1.47:1.
These are kept subtle **to stay honest to the real app** (the app's own `searchBorder` on
background is also 1.72:1). They are decorative parts of a non-interactive illustration,
not UI components, so the 3:1 non-text rule does not apply. Lightening them would misrepresent
the product.

---

## 3. Accessibility

- **`:focus-visible`** added: `a:focus-visible { outline: 3px solid var(--accent);
  outline-offset: 3px; }` — covers nav links, download buttons, ghost links, brand, footer
  links. (Page previously had no focus styling and no `outline:none` to suppress it.)
- **Heading hierarchy**: `h1` → `h2` ×3 (Features / Privacy / Download) → `h3` ×6 (tiles).
  No skipped levels. ✅
- **`aria-hidden="true"`** added to the decorative product mock (`.window`) and the
  flagship-tile search demo (`.demo`).
- **Alt text**: the only image is the brand icon, `alt=""` — intentionally empty because it
  is decorative and adjacent to the visible "Engram" text (an alt value would create a
  duplicate accessible name). Verified as correct.
- **`lang="en"`** already present on `<html>`. ✅
- **Media queries intact**: `prefers-reduced-motion`, `prefers-reduced-transparency`
  (updated to drop the now-opaque `.window`), and `prefers-contrast` all remain.

---

## 4. Link resolution (curl HEAD, follow redirects)

| Link | Result |
|---|---|
| `https://github.com/behnambm/engram/releases/latest/download/Engram.dmg` | **200** (302 → signed release-assets CDN → 200) ✅ |
| `https://github.com/behnambm/engram` | **200** ✅ |
| `https://github.com/behnambm` (footer) | **200** ✅ |

---

## Deferred

1. **App-side contrast** (secondaryText `#77788C` on `#16172F` = 4.05, on searchBackground
   = 3.50, searchBorder 1.72, etc.) — owned by `app-ux` (`Sources/Engram/`), out of my
   write scope.
2. **Mock border/divider subtlety** — kept to match the product (see §2 note).

Nothing else deferred. No HTML/CSS validation was run beyond the above (no build step for
a static file); the diff is small and localized.
