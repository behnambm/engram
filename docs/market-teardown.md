# macOS Clipboard Manager Teardown (search + filtering at scale)

Verification legend: **[V]** = fetched/verified this session · **[P]** = verified by parent agent · **[U]** = unverified (prior knowledge, treat as hypothesis).

Tooling note: `web_search` was unavailable (no API key) and the self-hosted Firecrawl at `127.0.0.1:3002` was down (`HTTP 000`). Everything **[V]** below came from `web_fetch` + `raw.githubusercontent.com` + `api.github.com`.

---

## 1. Maccy — verified source-level architecture

Repo: https://github.com/p0deje/Maccy (MIT, free, macOS 14+, MAS + GitHub/Homebrew). README claims "Lightweight and fast", "* Lightweight and fast * Keyboard-first * Open source and free" [V].

### 1.1 Persistence: SwiftData over a single SQLite file

`Maccy/Storage.swift` [V]:

```swift
import SwiftData
@MainActor class Storage {
  var container: ModelContainer
  var context: ModelContext { container.mainContext }
  private let url = URL.applicationSupportDirectory.appending(path: "Maccy/Storage.sqlite")
  init() { var config = ModelConfiguration(url: url)
           container = try ModelContainer(for: HistoryItem.self, configurations: config) }
```

- Engine: **SwiftData** (Core Data stack under the hood) → on-disk single SQLite store, WAL sidecars implied.
- Path: `~/Library/Application Support/Maccy/Storage.sqlite`. **No custom index, no FTS, no GRDB.**
- Schema: `@Model class HistoryItem` + child `@Model HistoryItemContent` (one row per pasteboard UTI). Fields include `application`, `firstCopiedAt`, `lastCopiedAt`, `numberOfCopies`, `pin`, `title`, `imageData` [V].
- Images are stored as `Data` blobs **inside the DB** [V] — this is what makes `Storage.sqlite` grow fast for screenshot-heavy users (README/settings surface DB file size as a UI string via `Storage.size`).
- `Storage.swift` carries three self-healing/GC passes: `cleanupOrphanedContents()` (predicate `item == nil`), `removeUnpersistableContents()`, and `sanitizeTitles()` — the last one exists because bad Unicode in stored titles made **Maccy spin at 100% CPU on every launch without drawing a window** (comment cites issue #1520) [V]. That is a direct, code-level admission of a scaling failure mode.

### 1.2 Pasteboard polling: 500 ms `Timer` + `changeCount`

`Maccy/Clipboard.swift` [V]:

```swift
func start() {
  timer = Timer.scheduledTimer(timeInterval: Defaults[.clipboardCheckInterval],
    target: self, selector: #selector(checkForChangesInPasteboard), userInfo: nil, repeats: true)
}
@objc func checkForChangesInPasteboard() {
  guard pasteboard.changeCount != changeCount else { return }
  changeCount = pasteboard.changeCount
  ...
```

- Default interval **0.5 s**, from `Defaults.Keys.clipboardCheckInterval` (`default: 0.5`) [V].
- Cheap guard: `NSPasteboard.changeCount` compare, so idle CPU is a 2 Hz wake-up that does nothing. No `NSPasteboard` change notification API exists, so polling is universal in this category.
- README documents lowering it: `defaults write org.p0deje.Maccy clipboardCheckInterval 0.1` [V].
- Per-tick work beyond the guard: ignore-list checks (pasteboard types, source app bundle), then reads/merges contents of **all** pasteboard items [V].

### 1.3 Search: in-memory array filtering, no SQL, no NSPredicate

`Maccy/Search.swift` (the whole file is ~150 lines) [V]:

```swift
private let fuse = Fuse(threshold: 0.7) // threshold found by trial-and-error
private let fuzzySearchLimit = 5_000
func search(string: String, within: [Searchable]) -> [SearchResult]   // Searchable == HistoryItemDecorator
```

- Modes: `exact` (default), `fuzzy`, `regexp`, `mixed` (exact → regexp → fuzzy, first non-empty wins) [V].
- Implementation is `within.compactMap { ... }` over the **full in-memory `[HistoryItemDecorator]`**, then `sorted(by: score)` for fuzzy [V]. There is **no index, no DB query, no background queue** — the DB is never asked to filter.
- Fuzzy inputs are truncated: `if searchString.count > fuzzySearchLimit { ... }` with `fuzzySearchLimit = 5_000`, comment `// shortcut to avoid slow search` [V].
- **It searches `item.title` only**, i.e. the display string, which `HistoryItem.generateTitle()` truncates to 1_000 characters with the comment `// 1k characters is trade-off for performance` [V]. A clip's 3,000th character is unsearchable. `HistoryItemDecorator.text` is separately shortened to `10_000`, and `highlight()` truncates to `500` [V].
- Query wiring, `Maccy/Observables/History.swift` [V]:

```swift
var searchQuery: String = "" { didSet(previous) { guard searchQuery != previous else { return }
    throttler.throttle { [self] in updateSearchResults() ... } } }
private let throttler = Throttler(minimumDelay: 0.2)
private func updateSearchResults() {
  filteredPinnedItems   = filteredItems(from: search.search(string: searchQuery, within: allPinnedItems))
  filteredUnpinnedItems = filteredItems(from: search.search(string: searchQuery, within: allUnpinnedItems))
}
```

So: **a 200 ms debounce on the main actor, then a synchronous O(n) scan plus O(n) `AttributedString` highlighting of every result.** Typing at 10 chars/sec with 999 items = up to ~5 full rescans/sec, each with highlight rendering. This is the mechanism behind the user complaints in §1.6.

### 1.4 Loading: fetch everything, then trim

`History.load()` [V]:

```swift
let descriptor = FetchDescriptor<HistoryItem>()      // no fetchLimit, no predicate
let results = try Storage.shared.context.fetch(descriptor)
let decorators = sorter.sort(results).map { HistoryItemDecorator($0) }
...
limitHistorySize(to: Defaults[.size])
```

- The store is read **entirely** into RAM and decorated (one `HistoryItemDecorator` per row, each with image/lazy-thumbnail state), then trimmed to `Defaults[.size]` — default **200**, and the settings slider tops out at 999 (issue #189 and #133 both say "999 items" / "maximum history capacity (999)") [V].
- No pagination, no fetch batching: open latency scales with rows in the DB, not with rows displayed.
- `HistoryItem.generateTitle()` for image clips kicks off Vision OCR **asynchronously** on a dedicated queue (`qos: .utility`, `VNRecognizeTextRequest`, `.accurate`, `automaticallyDetectsLanguage = true`) and overwrites `title` with the recognized text [V] — so OCR text *is* searchable, but only because it was copied into the searched field, and OCR runs after the copy, not at query time. On a large image backlog this is a CPU spike source [U on cost, V on implementation].

### 1.5 Rendering 999 items: SwiftUI `LazyVStack`, not NSMenu/UITableView

`Maccy/Views/HistoryListView.swift` + `Views/MultipleSelectionListView.swift` [V]:

```swift
ScrollView { ScrollViewReader { MultipleSelectionListView(items: unpinnedItems) { ... HistoryItemView(item: previous, item, next, index) } } }
// MultipleSelectionListView body:
LazyVStack(spacing: 0) { forEachModifier(EnumeratedForEach(data: items) { element, index in ... }) }
```

- Form factor: **custom floating `NSPanel`** — `FloatingPanel.swift` subclasses `NSPanel` with `.nonactivatingPanel, .resizable, .fullSizeContentView`, `isFloatingPanel = true`, `animationBehavior = .none` [V]. Not an `NSMenu` (that was the 0.x/1.x design), not a Dock app.
- Only visible rows are instantiated (`LazyVStack`); row height is measured via `GeometryReader` → `appState.popup.resize(height:)` [V].
- Per-row heavy work is deferred into `Task`s: `ensureThumbnailImage()` / `ensurePreviewImage()` with `previewImageGenerationTask` / `thumbnailImageGenerationTask`, and there is a global `ApplicationImageCache` for app icons [V]. Preview images are generated lazily on hover/selection delay (`previewDelay` default 1500 ms) [V].
- Net effect: **view layer is fine at 999; the popup cost is dominated by `load()` + `updateSearchResults()`, not by drawing.**

### 1.6 Paste / pin / dedupe behavior [V]

- `↩` / `⌘n` / click → copy to clipboard only. `⌥↩` / `⌥click` / `⌥n` → **paste into frontmost app**. `⌥⇧↩` → **paste without formatting** (README) [V].
- `Defaults.pasteByDefault` (default `false`) toggles copy-vs-paste-on-click [V].
- `⌘1`…`⌘9` are bound to the **first 9 visible unpinned** items (`updateUnpinnedShortcuts()` iterates `shortcutItems.prefix(9)`) [V]. Pinned items get single-character pin keys drawn from `supportedPins` with reserved keys removed (`v`, `q`, `a`, `z`, `,`, backtick, plus delete/pin/preview keys) [V].
- Dedupe is real and good: `add()` → `findSimilarItem(item)` → transfers contents, `numberOfCopies += existing`, keeps `firstCopiedAt`, inherits `pin`, deletes the old row ("Removing duplicate item") [V].
- Editable items: no user-facing edit of clip text [U]; pins are the only mutation.

### 1.7 Known performance ceilings — user evidence, with URLs

| Issue | State | Claim |
|---|---|---|
| [#189 Search/filter is slow](https://github.com/p0deje/Maccy/issues/189) | closed | *"My one complaint with it is that the filtering (in the popup or menu) is slow - given 999 items I'd expect it to be much faster. I can see a noticeable lag between typing a word and it appearing in the search box and the items filtering down"* |
| [#845 Search using first N symbols to increase search performance](https://github.com/p0deje/Maccy/issues/845) | **open** | *"big items make search much slower… Copy 20 strings of sizes between 5 symbols and 5 million symbols (total 55MB)… it was very slow. During search, Maccy becomes unresponsive (eventually it will finish the search in a few seconds)"* |
| [#133 Slow response](https://github.com/p0deje/Maccy/issues/133) | closed | *"Maccy is going the wrong way, getting slower and slower… As a user I want to use the maximum history capacity (999), and when I press the shortcut it loads the popup quickly, I can search quickly"* |
| [#36 Sometimes slow and then old list](https://github.com/p0deje/Maccy/issues/36) | closed | *"it takes a few seconds to load the list… I'm always being presented an old list"* (was on historySize 1000) |
| [#384 memory increases linearly](https://github.com/p0deje/Maccy/issues/384) | **open**, 72 comments | *"the memory occupation of the application will gradually increase (it seems to grow linearly and there is no sign of release)"* |
| [#1484 Maccy list not responsive](https://github.com/p0deje/Maccy/issues/1484) | closed, 32 comments | unresponsive list on macOS 26 (body is mostly a settings dump; title is the signal) |
| [#310 unlimited clipboard data](https://github.com/p0deje/Maccy/issues/310) / [PR #1262](https://github.com/p0deje/Maccy/pull/1262) | **open** | unlimited-history request open since 2021 (55 comments); an "unlimited history" PR is still unmerged as of this teardown |
| [#1520 (cited in `Storage.swift`)](https://github.com/p0deje/Maccy/issues/1520) | — | stored titles with bad scalars → **100% CPU spin on launch, window never draws** |

Pattern: **every ceiling is the same ceiling** — full-table load + full-array scan + highlight-all on the main thread, with hard caps (999 items, 1k-char searchable title, 5k-char fuzzy input) bolted on to keep it survivable.

---

## 2. Product-by-product

### Paste (Paste Team) — [P] ratings + [V] pricing
- Form factor: Dock app with a full-window horizontal timeline of cards; hotkey brings the window forward. Not a dropdown. [U on exact chrome]
- Search: yes, live + fuzzy; filters by content type and source app via the cards UI; no regex [U].
- Storage: **"Unlimited clipboard history, pinboards, search, and sync"** — from the marketing/pricing copy [V]. DB technology not disclosed [U: Core Data + iCloud sync].
- Paste behavior: click/return pastes into the frontmost app (its core promise); plain-text variant via modifier [U].
- Pinning/pinboards/snippets: **pinboards** (named collections) are the flagship feature; snippets exist [V via pricing copy]. Editable clip text: yes [U].
- Price/distribution: **$2.49/mo, $29.99/yr annual, Lifetime tier exists, 7-day trial, Setapp included, App Store + direct + iPhone/iPad** [V]. MAS id 967805235, 4.20/5, n=1345 [P].
- Complaints: subscription-only model is the recurring gripe (many 1★ MAS reviews cite "used to be one-time purchase") [U]; iCloud sync conflicts [U]. Slowness at scale: **no notable reports** — it caps by age and syncs, and App Store reviews don't surface a lag theme [U].

### Pastebot 3 (Tapbots) — [V]
- Form factor: menu-bar item + **quick paste menu (⇧⌘V)** overlay in any app; separate stack window and preview window [V].
- Search: yes, live, with **searchable per-clipping notes** and metadata sidebar [V]. Filters: the strongest in the category — stackable/compound **custom filters**, **rule-based Smart Pastebins**, filter hotkeys, live preview while building a filter [V].
- Storage: no published cap found [U]; iCloud Sync of clippings/pastebins/filters [V]. DB tech undisclosed [U].
- Paste: number keys paste **any of the last 10 copies** from the quick paste menu [V]; sequential **Stack** paste with ⌃⌘V [V].
- Pinning: Custom Pastebins (color/icon) + Smart Pastebins + per-clipping keyboard shortcuts [V]. CLI: `/Applications/Pastebot.app/Contents/Helpers/pastebot-tool` and Apple Shortcuts [V].
- Price: **$39 direct incl. 1 yr updates, $19/yr renewal thereafter; App Store $24.99/yr or $2.99/mo; macOS 26 Tahoe+ only; 14-day trial** [V].
- Complaints: price and the macOS 26 requirement are the visible friction points [U]; no scale-lag reports found [U].

### Alfred clipboard history — [V]
- Form factor: **command palette** (Alfred's launcher window), not a dropdown [V].
- Search: yes — *"start typing any word or phrase from the original clip you copied to see matching results"* [V]; word/phrase containment, not fuzzy [U].
- Filters: **none by app*/type (*ignore-list only) — filtering is by retention window: "24 hours, 7 days, 1 month or 3 months"** [V]. No pinning of clips; the mechanism for keeping a clip is **save-as-snippet (⌘S)** [V].
- Storage: time-boxed rather than count-boxed; `max clip size` setting to *"ignore any copied text over the specified limit to prevent accidental Clipboard History bloating"* [V]. DB tech undisclosed [U].
- Paste: *"Pasting on Return is active by default"*, plus optional auto-paste into the active app [V]. Clipboard **Merging** (⌘C⌘C appends) [V].
- Price: Powerpack-licensed, one-time, no subscription [U: £34 single / £59 mega lifetime]. Direct only (not MAS) [U].
- Complaints: `clear`→rebuild DB is the official troubleshooting step, which implies a database that corrupts/bloats [V]; no search filters and no pins is the common feature complaint [U].

### Raycast Clipboard History — [V]
- Form factor: **command palette** (single Raycast window, list + detail pane) [V].
- Search: live typing filters the left list [V]; content-type filter on **⌘P** [V]; no app/date filters [U]; fuzzy [U].
- Storage: **encrypted at rest, local only; "history can be kept until 3 months"** [V]. Count cap not published [U: 3 months + internal limit].
- Paste: `↩` *"to copy selected entry to your clipboard manager"* — i.e. **copy, not auto-paste** [V]; "paste as plain text or rich text as needed" [V]. Pin: **⌘⇧P** [V]. Delete: ⌃X / ⌃⇧X [V].
- Price: free core extension; Pro subscription for AI/cloud [U: $8/mo annual, $10/mo monthly]. Direct distribution.
- Complaints: Raycast's **RAM footprint** is a standing HN/Reddit complaint [U]; 3-month history window is a hard ceiling for archive-style use [V]. Clipboard history itself is generally seen as fast [U].

### PastePal (Khoa Pham) — [P] ratings
- Form factor: menu-bar dropdown panel + hotkey [U].
- Search: yes, live, fuzzy; **filters by app / content type / date** and a "collection" concept [U].
- Storage: configurable history size, no published hard cap [U]; sync via iCloud [U]. DB tech undisclosed [U].
- Paste: return-to-paste, ⌘1-9 quick paste, plain-text paste [U].
- Pinning/snippets: yes, plus snippets and per-clip notes [U].
- Price: free with one-time Pro IAP (~$9.99) and/or yearly [U]. MAS id 1503446680, 4.14/5, n=192 [P].
- Complaints: small review base; sync and pricing-model churn noted [U]. No scale-lag theme established [U].

### PasteNow — [U] (no primary source fetched)
- Form factor: menu-bar dropdown with a search field and item preview.
- Search: live search + app filter; pin/star support.
- Storage: reason for existing is *"fast with large history"*; no published cap found.
- Paste: copy-on-click + return-paste, ⌘1-9.
- Price: one-time low-cost on the Mac App Store. **All of the above unverified** — do not ship in a doc without re-checking.

### LaunchBar — [U]
- Form factor: command palette (launcher), clipboard history is one of many "browsable" destinations.
- Search: clipboard history browsing exists, but no dedicated fuzzy filter field for clips; you type in the bar.
- Storage: **small, count-capped history** (the classic complaint vs. dedicated managers); users treat it as a convenience, not an archive.
- Paste: return-pastes into frontmost app.
- Price: one-time (~$29) direct.
- Complaints: history too shallow, no per-app/type filters. **Unverified.**

### Clipy — [U]
- Form factor: menu-bar `NSMenu` dropdown (classic style).
- Search: **no search field in the menu**; relies on the submenu hierarchy and ⌘1-9.
- Storage: history-count setting; plain-text/`Realm`? (historical: it used Core Data then switched) — **unknown, unverified.**
- Paste: copy-on-click by default (`Paste` option available), ⌘1-9.
- Pinning: yes (pin list), snippets.
- Price: free, MIT, on GitHub + MAS. Complaints: project largely unmaintained, crash/arm64 issues. **Unverified.**

### CopyClip / CopyClip 2 (FIPLAB) — [P] prices
- Form factor: menu-bar dropdown list; no search UI in the free 1.x (CopyClip 2 adds search) [U].
- Storage: fixed count (10/20/30/…/100) selectable in prefs [U].
- Paste: click-to-paste; no ⌘1-9 [U].
- Pinning: "favorites" added in CopyClip 2 [U]. Editable: no.
- Price: CopyClip free (v1.9.88); **CopyClip 2 $7.99 on the MAS with 0 ratings** [P]. Not sandboxed-limited in any interesting way.
- Complaints: minimal feature set; MAS rating of record is empty for v2 [P]. No scale-lag data [U].

### Pieces for Developers — [U]
- Form factor: **Dock app with a window** (workstream/"memory" surface), not a dropdown; plus IDE/editor integrations.
- Search: natural-language/AI search across long-term memory, plus text search; per-app/metadata filters.
- Storage: cloud-backed long-term memory (that's the product), local capture agent.
- Paste: click-to-copy, drag-out; snippets as "saved materials".
- Price: free tier + Pro subscription (~$10/mo). Direct distribution.
- Complaints: privacy (cloud), footprint, and it being overkill as a clipboard manager. **All unverified.**

### Other notable — [U]
- **Flycut**: free/MIT, menu-bar dropdown, no search, count-capped, essentially frozen upstream.
- **ClipMenu**: free, abandoned (~2015), classic `NSMenu` with search field — historically the reference "fast at 999" implementation because it used flat files, not a DB.
- **Clippy**: old free menu-bar manager, abandoned.
- **Clipboard Manager (AppYogi)**: MAS, ~$1.99 one-time, plain list, no modern search.

---

## 3. Comparison table

| Product | Form factor | Search | Filters (app/type/date) | Pinning / snippets | Storage limit | Price | Known slow at scale |
|---|---|---|---|---|---|---|---|
| **Maccy** [V] | menu-bar + **NSPanel** SwiftUI popup (LazyVStack) | live, exact/fuzzy/regex/mixed; OCR text of images; **title only, 1k chars** | none (pins only) | pins (⌥+key) + ⌘1-9; no snippets | 200 default / **999 max**; SwiftData SQLite; blob images | free, MIT, MAS + Homebrew | **YES — strongest evidence**: [#189](https://github.com/p0deje/Maccy/issues/189), [#845](https://github.com/p0deje/Maccy/issues/845), [#133](https://github.com/p0deje/Maccy/issues/133), [#384](https://github.com/p0deje/Maccy/issues/384) |
| Paste [V/P] | Dock app, timeline window | live + fuzzy | type + app (UI-driven) | **pinboards** + snippets | "unlimited history" [V] | $2.49/mo · $29.99/yr · lifetime · Setapp | no notable reports [U] |
| Pastebot 3 [V] | menu-bar + **⇧⌘V quick paste overlay** | live + per-clip notes | **stackable custom filters + Smart Pastebins** | pastebins + per-clip hotkeys | not published [U]; iCloud sync | $39 direct (+$19/yr) · MAS $24.99/yr | none found [U] |
| Raycast [V] | command palette | live, type filter ⌘P | type only | pin ⌘⇧P | **3 months** retention, encrypted | free core; Pro ~$8/mo [U] | app-level RAM complaints [U] |
| Alfred [V] | command palette | live word/phrase | none; **time retention 24h/7d/1mo/3mo** + max-clip-size | snippets (⌘S) only | time-boxed | Powerpack lifetime [U] | no lag reports; DB rebuild is official fix [V] |
| PastePal [P/U] | menu-bar panel | live + fuzzy | app/type/date | pins + snippets | configurable [U] | free + one-time Pro [U] | unknown [U] |
| PasteNow [U] | menu-bar panel | live | app filter | pins | unknown | low one-time [U] | sells "fast w/ big history" [U] |
| LaunchBar [U] | command palette | no dedicated clip search | none | none | small count cap | ~$29 one-time [U] | shallow by design [U] |
| Clipy [U] | menu-bar NSMenu | **no** | none | pins + snippets | count cap | free, MIT | unmaintained [U] |
| CopyClip / 2 [P/U] | menu-bar dropdown | v2 only | none | favorites (v2) | 10–100 clips | free / **$7.99** | no search to be slow [U] |
| Pieces [U] | Dock app window | AI/NL search | metadata | snippets | cloud | free + ~$10/mo | footprint complaints [U] |
| PasteBar [V] | menu-bar + boards window | searchable (screenshots) [V] | collections/tabs/boards [V] | custom clips + templates [V] | **unlimited, local** [V] | free/OSS (+Pro) [V] | Electron-class footprint [U] |
| Flycut / ClipMenu / Clippy / AppYogi [U] | menu-bar dropdown | none / trivial | none | minimal | small | free / ~$2 | abandoned [U] |

---

## 4. Top 5 unmet needs, ranked by evidence strength

1. **Sub-frame search latency that does not degrade with history size.** Evidence is unusually direct: Maccy ships *hard-coded truncations* to survive (`fuzzySearchLimit = 5_000`, title 1k, highlight 500) and users still report multi-second unresponsive searches at 55 MB of history ([#845](https://github.com/p0deje/Maccy/issues/845)) and visible keystroke lag at 999 items ([#189](https://github.com/p0deje/Maccy/issues/189), [#133](https://github.com/p0deje/Maccy/issues/133)). **No product in the set advertises a measured latency at 100k items.** Gaps: FTS5/BM25 + trigram index instead of `compactMap`; search off the main actor; highlight only visible rows.
2. **History that is genuinely unbounded.** [#310](https://github.com/p0deje/Maccy/issues/310) has been open since 2021 with 55 comments, the "unlimited history" PR [#1262](https://github.com/p0deje/Maccy/pull/1262) is unmerged, Raycast stops at 3 months, Alfred stops at 3 months or a size cap, Maccy caps at 999. Every respondent wants Ditto-like retention with none of the Ditto-like slowness.
3. **Search the full clip, not a truncated title.** Code-level proof: Maccy indexes `item.title`, which `generateTitle()` cuts at 1,000 chars ("trade-off for performance") [V]. Practically nobody can find a string in the middle of a log dump. A full-text index over the whole payload is the single clearest technical differentiator.
4. **Saved, composable filters + quick-paste stacks.** Only Pastebot 3 has real filter stacking and Smart Pastebins [V]; everyone else offers pins only. Filtering by app/type/date is the exact intersection the brief cares about, and it's mostly absent above.
5. **Steady-state memory and idle CPU.** [#384](https://github.com/p0deje/Maccy/issues/384) (open, 72 comments, memory "grows linearly and has no sign of release"), plus the 500 ms polling loop with merged multi-item reads [V] and image blobs kept in the SQLite store [V]. A memory budget (streamed rows, thumbnails on disk, capped caches) is a sellable, verifiable claim.

---

## 5. Table stakes vs differentiators

**Table stakes (must exist or it isn't a contender):**
1. Global hotkey → instant panel, keyboard-first flow: type-to-filter, `↩` copy, `⌥↩` paste, `⌥⇧↩` plain text (Maccy's exact grammar is now the category default) [V].
2. Pins/favorites with dedicated quick-paste slots (`⌘1`–`⌘9` + single-key pins) and snippet promotion [V].
3. Password-manager + transient-type + source-app ignore rules, local-only storage (Alfred, Raycast, Maccy, Pastebot all ship this) [V].

**Differentiators (win the brief):**
1. **A real index**: SQLite FTS5 + trigram/fuzzy over the *whole* payload, incremental query, main-thread-free — pitch a number ("filter 5 ms at 1M clips, p99"), since today's ceiling is 999 items [V].
2. **Filters as first-class saved objects**: by app, by type (text/link/image/code/color/file), by date range, by regex, combined into named smart views with hotkeys — Pastebot-only today [V].
3. **On-device image/OCR/semantic search**: Maccy already runs Vision OCR but only after copy and only into the display title [V]; doing it at ingest with an indexed store turns screenshots into searchable history (needs an honest CPU/battery story).

---

## 6. Unverified items to re-check before publishing
- Prices: Alfred Powerpack, Raycast Pro, Paste Lifetime tier, PastePal Pro, PasteNow, LaunchBar, Pieces, PasteBar Pro — none fetched.
- PasteNow, LaunchBar, Clipy, CopyClip 2, Pieces, Flycut, ClipMenu, Clippy, AppYogi: every row is **[U]**; no primary source was read this session.
- DB engines for every vendor except Maccy (SwiftData/SQLite) — none disclose; PastePal/Pastebot/Alfred/Raycast/Clipy rows are inference only.
- Complaint quotes beyond Maccy's issue tracker (Raycast RAM, Paste subscription anger, iCloud sync failures) are recollected, not sourced.
- Reddit/HN threads: **not searched** (web_search broken, Firecrawl down) — the user-voice section rests entirely on GitHub issues.
