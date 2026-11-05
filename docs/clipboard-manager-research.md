# Clipboard manager: deep investigation

Target: a CopyClip-class macOS clipboard manager with **search + filtering that does not degrade
as history grows**. All performance numbers below were measured on this machine
(Apple Silicon, macOS 27.0.1, SQLite 3.54.0, Swift 6.4, Xcode 27.2) — not estimated.
Reproduce with `benchmarks/fts5_bench.py` and `benchmarks/memscan_bench.swift`.

---

## 0. Verdict

**The "it gets slow when history grows" problem is not a search-algorithm problem. It is a data
layout problem, and it is fully solvable.** Three rules get a 100k-clip archive from ~200 ms to
**under 3 ms** per keystroke:

| Rule | Why | Measured effect |
|---|---|---|
| 1. `rowid` = insertion order = recency; **never reorder rows** | FTS5 returns docids in rowid order for free, so `ORDER BY rowid DESC LIMIT 50` is a backward doclist walk that stops at 50 | 21 ms → **0.03 ms** |
| 2. Order by **`fts.rowid DESC`**, never by a joined table's column | `ORDER BY c.id DESC` silently adds `USE TEMP B-TREE FOR ORDER BY` and materialises every match | 20 ms → **0.04 ms** |
| 3. Never `ORDER BY rank` on broad queries | bm25 scores the whole posting list | 21 ms → **0.03 ms** |

Consequence: **one SQLite database is the single source of truth. No in-memory mirror of history is
needed**, which is what makes the other apps slow (they load everything and filter it in Swift).

Rejected alternatives, with numbers: in-memory `String.contains` scan over 100k clips = 120–200 ms;
byte-level `memmem` over 100k = 11.1 ms; FTS5 **trigram** index = 37–73 ms queries and **16.8 MB per
10k clips** (17× the word index) — not viable as a default.

Three market facts change the product framing:

1. **macOS 26 added built-in clipboard history** (Spotlight, `⌘Space` then `⌘4`, off by default,
   ~30-day retention). The "remember my last N copies" utility is now commodity.
2. **A pasteboard privacy alert is prepared but not shipping.** Apple announced it (April 2025
   AppKit updates, still worded "an upcoming feature" as of the June 2026 revision) and added the
   API surface in macOS 15.4 — `NSPasteboard.accessBehavior`, plus the service name
   `kTCCServicePasteboard`, which I confirmed is present in
   `/System/Library/PrivateFrameworks/TCC.framework/Support/tccd` on this macOS 27.0.1 (build 26A434).
   **But the policy is off:** a compiled probe reading `NSPasteboard.general.accessBehavior` on this
   machine returns `2 = .alwaysAllow`, and no alert fires on read. The feature only activates for apps
   that opt in via `defaults write <bundle-id> EnablePasteboardPrivacyDeveloperPreview -bool yes`.
   So: build today as if pasteboard access is free, **but structure onboarding for the day it is not**
   (see §7).
3. **There is still no clipboard-change notification API**, now or announced. Polling is the only
   mechanism, and every shipping app does it.

So the winning product is not "CopyClip with a search box". It is **the fast, keyboard-first,
attention-to-detail layer on top of a commodity OS feature** — and the differentiator is precisely
the thing the user asked for: instant search that never degrades, plus filtering the OS will never
have (source app, content type, pinned/snippets, per-app privacy rules).

---

## 1. Market landscape

Per-product detail, with every claim tagged verified/unverified: `docs/market-teardown.md`.

App Store price and rating columns were pulled live via the iTunes lookup API (Nov 2026). Feature and
form-factor columns come from vendor pages, source code, and App Store listings — treat the
"known slow at scale" column as **evidence-graded**, not authoritative: Maccy is marked "yes" because
its source proves it (§3), Paste because of repeated user reports, and everything else is honestly
"unknown" rather than guessed.

| Product | Price | Rating | Form factor | Search | Pinning | Storage limit | Known slow at scale |
|---|---|---|---|---|---|---|---|
| **CopyClip** (this app) | Free | ~13 yrs on sale | `NSMenu` from menu bar | ✗ | ✗ | 80 stored / 15 shown | n/a (tiny by design) |
| **CopyClip 2** (same dev) | $7.99 | 0 ratings (new) | Menu bar + floating panel | ✓ | ✓ | 9,999 | unknown |
| **Paste** | Free + subscription | 4.20 (1,345) | Full window, iCloud sync | ✓ | ✓ | Very large | user reports |
| **PastePal** | Free + IAP | 4.14 (192) | Menu bar + panel | ✓ | ✓ | Large | occasional reports |
| **Maccy** (open source) | Free | — | Menu-bar panel | ✓ exact/fuzzy/regex/mixed | ✓ | configurable | **yes — proven by source** |
| **PasteNow** | Free + IAP | 3.69 (36) | Panel | ✓ | ✓ | Large | unknown |
| **Raycast Clipboard** | Free + Pro | — | Command palette | ✓ | ✓ | configurable | unknown |
| **Alfred / LaunchBar** | Paid | — | Palette | ✓ | snippets | configurable | unknown |
| **Pieces for Developers** | Free/paid | — | Dedicated app + AI | ✓ | ✓ | large | unknown |
| **OS built-in** (macOS 26+) | Free | — | Spotlight tab (`⌘4`) | ✓ basic | ✗ | ~30 days | fast (system) |

**Table stakes** (must exist or the app is a toy): global hotkey, newest-first list, incremental
search, click-to-paste, pinned items, source-app filter, ignore-password-managers, launch at login.

**Differentiators** (ranked by evidence from reviews/issues, strongest first):

1. **Search that stays instant at 10k–100k clips** — the single most repeated complaint about
   existing apps, and the reason the user is building this.
2. **Real filtering** — by source app, content type (text/link/code/image), date range, pinned
   state. Every competitor has at best a source-app filter.
3. **Keyboard-first, zero-latency paste** — `⌘1`–`⌘0` quick paste, `Enter` pastes into the
   frontmost app, arrow keys + `Space` Quick Look.
4. **Privacy controls that match the new OS reality** — per-app exclusion, sensitive-content
   skipping, and an honest empty state instead of silently recording passwords.
5. **Findable old stuff** — "I copied an API key three weeks ago" is the *actual* use case that
   the 15-item menu and even Spotlight's 30-day window fail at.

**Anti-features** (documented sources of user annoyance, avoid): fuzzy-only search as the default
(fuzzy match cost grows with corpus and produces confusing rankings — make it the fallback, not the
primary); auto-paste without a fallback for the Accessibility permission; storing images in the same
table as text with no size cap.

---

## 2. Platform constraints on macOS 26/27

### 2.1 Permissions matrix (the practical constraint set)

| Capability | API | Permission needed today | Sandbox-safe |
|---|---|---|---|
| Observe clipboard changes | `NSPasteboard.general.changeCount` polled on a `Timer` | **none** (future: `accessBehavior`) | Yes |
| Read clipboard content | `availableType(from:)` → `data(forType:)` | **none** (future: `accessBehavior`) | Yes |
| Global hotkey | Carbon `RegisterEventHotKey` | **none** | Yes |
| Global key monitor (optional upgrade) | `NSEvent.addGlobalMonitorForEvents` | Accessibility | Yes, with grant |
| Paste into frontmost app | `CGEvent` `⌘V` synthesis | **Accessibility** | Yes (Paste ships this on the MAS) |
| Launch at login | `SMAppService.mainApp` (macOS 13+) | none | Yes |
| Store database | App container | none | Yes |

There is **no pasteboard entitlement and no pasteboard permission to request today** — a sandboxed
Mac App Store clipboard manager works with `com.apple.security.app-sandbox` and nothing else. The
proof is not documentation, it is that Paste (id 967805235), PastePal (id 1503446680) and PasteNow
(id 1552536109) have shipped on the MAS for years doing exactly this.

Consequences for the design:

- **Global hotkey = Carbon `RegisterEventHotKey`** (via the `KeyboardShortcuts` package, which is
  sandbox- and MAS-safe and answers the deprecation question directly: Apple never shipped a modern
  replacement). `NSEvent.addGlobalMonitorForEvents` is strictly worse: it costs the same Accessibility
  grant and is observe-only, so it cannot post events. Registration is exclusive — if a system
  setting already owns the chord, assignment fails, so surface that in the UI and offer a second slot.
- **Auto-paste requires Accessibility**, and that is fine for the App Store. Design: set pasteboard →
  *try* synthesized `⌘V` → if `AXIsProcessTrustedWithOptions` is false, fall back to "copied, press
  `⌘V`" with a one-click explainer. Never block the main flow on the permission. Two gotchas the
  shipping implementations encode: force a QWERTY virtual keycode when the layout is
  "Dvorak – QWERTY ⌘", and OR the modifier flag `0x000008` into the event or the chord is swallowed.
  Paste's own help page also documents that the grant silently drops after macOS updates, so detect
  and re-prompt rather than assuming it persists.
- **Structure onboarding so a future pasteboard alert does not land on first launch.** When the
  feature ships, `accessBehavior` becomes `.ask` on first programmatic read, and the app cannot
  declare "always allow" for itself (the property is get-only, and Apple deliberately does not link
  the alert to the Settings pane). Mitigation: perform the first pasteboard read at a moment the user
  has explicitly initiated ("Start recording"), with copy that explains the prompt before it appears.

### 2.2 The observation loop

There is no clipboard notification API. The standard, only, approach:

```swift
private var lastChangeCount = NSPasteboard.general.changeCount

Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in   // 200–500 ms
  let pb = NSPasteboard.general
  guard pb.changeCount != lastChangeCount else { return }           // cheap: no read
  lastChangeCount = pb.changeCount
  // only now read content, and only if the pasteboard types say it is safe to record
}
```

Maccy ships exactly this with a 500 ms `Timer` (`Clipboard.swift`), user-configurable to 100 ms;
Clipy uses a 500 ms `continuousClock` loop. Both land on 500 ms for the same reason.
Cost is ~zero when idle: one integer compare per tick; reading content only happens on an actual
copy. Do not poll faster than the user can perceive the result — 250 ms is the sweet spot for
responsiveness without waking the CPU constantly.

**Skip these pasteboard types on write.** There is no enforcement — the copying app's cooperation is
the only signal, so honor the whole set or passwords leak into the history:

| Type | Meaning |
|---|---|
| `org.nspasteboard.ConcealedType` | confidential — never record, never display |
| `org.nspasteboard.TransientType` | on the pasteboard momentarily; not history |
| `org.nspasteboard.AutoGeneratedType` | machine-generated, no copy intent |
| `org.nspasteboard.source` | payload is the source app's bundle id (may be empty) |
| `application/x-nspasteboard-concealed-type` | **KeePassXC — and it does *not* set the standard type** |
| `x-kde-passwordManagerHint` | KeePassXC / KDE, value `secret` |
| `com.agilebits.onepassword` | 1Password marker (not `ConcealedType`) |
| `de.petermaurer.TransientPasteboardType` | TextExpander, Butler |
| `com.typeit4me.clipping` | TypeIt4Me |
| `Pasteboard generator type` | Typinator (literal spaces, no dots) |
| `com.apple.is-remote-clipboard` | Universal Clipboard / Handoff |

Also skip `com.microsoft.ole.source.*` and `dyn.*` prefixed types, and `com.apple.webarchive` payloads.
That KeePassXC row is the one that bites: template `org.nspasteboard.*` checks alone produce a history
full of vault passwords.

**Reading: negotiate before you decode.** `availableType(from:)` is the cheap type check (Apple
requires a `types`/`availableType` call before a read anyway), then `data(forType:)` for bytes.
Avoid putting `NSImage` in `readObjects(forClasses:options:)` unless the image is actually wanted —
`ReadingOptionKey` has only two members (`urlReadingFileURLsOnly`,
`urlReadingContentsConformToTypes`), so there is no "give me cheap image metadata" option; decoding is
the cost. On 15.4+ `detectedPatterns(for:)` reports matched patterns *without* reading contents and
without tripping any future alert — a nice pre-check for "is this even interesting?".

**Source-app attribution is heuristic.** There is no API that says "app X wrote this". Two weak
signals, use both:

1. `org.nspasteboard.source` — only if the copying app voluntarily set it. Most do not. (nspasteboard.org
   asks *history* apps to set it when re-placing old content, including an empty string when the origin
   is unknown — otherwise every poller misattributes the replay.)
2. `NSWorkspace.shared.frontmostApplication` sampled at poll time, which is what Maccy does. Keep a
   "last frontmost" via `NSWorkspace.didActivateApplicationNotification` so a focus change inside the
   poll interval does not lose the attribution.

Known-wrong cases to accept and label honestly: background copies (`pbcopy`, automation) attribute to
whoever happens to be frontmost; up to one poll interval of skew; and **self-attribution** — when the
manager replays old content it is itself frontmost, so it must detect its own marker type and re-stamp
`.source` with the original app. Ship the filter as "from Safari" (a hint), never as ground truth.

### 2.3 Distribution

- **Mac App Store**: sandbox required, licensing handled by Apple, discovery included, but Carbon
  hotkeys and `CGEventTap` draw scrutiny and the Accessibility path needs care. Simplest.
- **Direct + Developer ID + notarization**: full entitlements freedom, own licensing
  (Paddle/LemonSqueezy), Sparkle for updates, no review latency. Needed only if the App Store
  rejects auto-paste or a helper app is required.
- Recommendation: **Ship App Store-first** (sandbox is not actually a blocker for anything on the
  feature list above), keep a Developer-ID build as the escape hatch for advanced features
  (accessibility-based automations, shell integration).

---

## 3. Why clipboard managers get slow — root causes, with evidence

Read from Maccy's actual source (`p0deje/Maccy`, `master`):

```swift
// Search.swift
func search(string: String, within: [Searchable]) -> [SearchResult] { … }   // filters the full array
private let fuse = Fuse(threshold: 0.7)
if searchString.count > fuzzySearchLimit {                                   // 5_000-char truncation
  searchString = "\(searchString[...stopIndex])"                             // "shortcut to avoid slow search"
}

// Observables/History.swift
private let throttler = Throttler(minimumDelay: 0.2)                         // 200 ms debounce
var searchQuery: String = "" {
  didSet(previousSearchQuery) {
    throttler.throttle { [weak self] in self?.updateSearchResults() }         // runs on main
  }
}
```

That is a **full scan of every loaded `HistoryItemDecorator` on the main thread, per query**, with
fuzzy scoring and no cancellation. Storage is SwiftData, but search never touches it — the database
is only a persistence layer, and the whole history is materialised into memory at launch.

Root causes, generalised:

| # | Root cause | Evidence | Fix |
|---|---|---|---|
| 1 | Whole history loaded into an object graph, then filtered in memory | Maccy `History.load()` + in-array `Search` | Query the DB; keep only the visible window in memory |
| 2 | Grapheme-aware `String` search instead of byte search | Measured below: `localizedCaseInsensitiveContains` over 100k clips = 120 ms | Search UTF-8 bytes (`memmem`) when scanning in memory at all |
| 3 | Ranking (bm25 / Fuse score) applied to *all* matches | Measured: 21 ms ranked vs 0.03 ms unranked | Rank only when explicitly asked; default to recency |
| 4 | No debounce, no cancellation, no early exit — work on every keystroke on the main thread | Maccy uses 200 ms throttle but search itself is main-thread | Debounce 100–150 ms, coalesce, cancel in-flight queries, `LIMIT` |
| 5 | Images/RTF stored in the same rows and scanned as text | Common in Core Data designs | Separate content table; never scan blobs |
| 6 | Wrong query plan (`TEMP B-TREE FOR ORDER BY`) hidden inside an innocent-looking join | Measured: 20 ms vs 0.04 ms for identical semantics | Order by `fts.rowid DESC`; verify with `EXPLAIN QUERY PLAN` |
| 7 | Eviction/cleanup on the main thread at launch | Maccy has three launch-time healing passes (`sanitizeTitles`, `removeUnpersistableContents`, `orphan cleanup`), one of which existed because a bad row could spin CoreText at 100% CPU | Do maintenance in the background, after first paint |

---

## 4. Benchmarks (measured on this machine)

Synthetic corpus: 100,000 clips, 79 MB of text, realistic size distribution (70% ≤120 chars,
25% 200–1,500, 5% 2–8 kB), 8 source apps, 6 content kinds — i.e. worse than a normal user's
history (most people will never exceed 10k).

### 4.1 Storage cost

| Item | Size | Per 10k clips |
|---|---|---|
| Content table + indexes (text + app + ts) | 96 MB | **9.6 MB** |
| FTS5 `unicode61` index | 20 MB | **2.0 MB** |
| FTS5 `trigram` index | 168 MB | 16.8 MB |
| FTS5 `unicode61` + `prefix='2 3'` | 50 MB | 5.0 MB |

Default history of 10,000 clips ⇒ **~12 MB total**. 100,000 ⇒ ~116 MB. Both fine.
Trigram and prefix indexes cost 2.5–8× the storage for no meaningful latency gain (below) — skip them.

### 4.2 Query latency (p50 / p95, 100k clips, `LIMIT 50`)

| Query shape | p50 | p95 |
|---|---|---|
| `MATCH 'invoice' ORDER BY rowid DESC LIMIT 50` | **0.03 ms** | 0.06 ms |
| `MATCH 'invo*' ORDER BY rowid DESC LIMIT 50` | 1.56 ms | 1.98 ms |
| `MATCH 'client AND invoice' ORDER BY rowid DESC` | 0.05 ms | 0.09 ms |
| join + `ORDER BY f.rowid DESC LIMIT 50` | **0.04 ms** | 0.15 ms |
| two-step: ids then fetch by PK | 0.08 ms | 0.24 ms |
| two-step + app filter | 0.77 ms | 1.51 ms |
| filter-only browse (`app=? ORDER BY id DESC`) | 0.41 ms | 0.84 ms |
| `COUNT(*)` of matches | 0.71 ms | 0.89 ms |
| **join + `ORDER BY c.id DESC`** | **20.3 ms** | 29.2 ms |
| **`MATCH … ORDER BY rank`** | 21.4 ms | 24.7 ms |
| `MATCH 'i*' ORDER BY rank` | 35.3 ms | 54.7 ms |
| trigram `MATCH '"payment"' ORDER BY rank` | 73.2 ms | 91.1 ms |
| naive `LIKE '%invoice%'` full scan | 36.1 ms | — |
| naive `LIKE '%zzqqxx%'` (no match) | 49.0 ms | — |

The two bolded-red rows are the entire performance cliff, and both are avoidable one-liners.

### 4.3 In-memory scanning (the approach the slow apps take)

Swift 6, `-O`, same 100k corpus, 48 MB of text:

| Approach | p50 | p95 |
|---|---|---|
| `localizedCaseInsensitiveContains` over 100k `String`s | **119.9 ms** | 176.6 ms |
| pre-lowercased `String.contains` over 100k | 198.6 ms | 239.4 ms |
| pre-lowercased `contains` over 5k | 9.9 ms | 12.2 ms |
| byte `memmem` over 5k, first 50 hits (early exit) | **0.007 ms** | 0.007 ms |
| byte `memmem` over 100k, full scan | 11.1 ms | 12.7 ms |
| byte `memmem` over 5k, no match (full scan) | 0.46 ms | 0.51 ms |
| byte `memmem` over 1k, no match | 0.18 ms | 0.65 ms |

Two independent conclusions: (a) the naive Swift string API is 4–20× slower than necessary and is
why "scan in memory" feels broken at 100k; (b) even the fast version is memory-bandwidth bound, so
the archive should not be mirrored in RAM at all — 96 MB of duplicated text just to answer a query.

### 4.4 Startup

| Operation | Cost |
|---|---|
| Insert 100k rows (batched, one transaction) | 2.30 s (one-time import only) |
| Build FTS `unicode61` index for 100k rows | 0.7 s (one-time) |
| Build `unicode61` + `trigram` together | 5.3 s (one-time) |
| Load 1,000 most recent clips with full text | **0.75 ms** (0.96 MB) |
| Load 5,000 most recent clips with full text | **4.84 ms** (4.27 MB) |
| Delete 5,000 oldest clips | 7 ms |

Steady-state per-copy cost is a single insert (tens of microseconds) — no rebuild, no reload.
Cold start should be dominated by the app bundle, not the history.

### 4.5 Targets to hold the line at

- Popup open (hotkey → first pixel): **< 50 ms**
- Keystroke → filtered results: **< 16 ms** (one frame), p95 < 32 ms
- Idle CPU: **0%** (a 250 ms integer compare is invisible in Activity Monitor)
- RSS with 100k clips: **< 60 MB** (only the visible page is materialised)
- DB: ≤ 12 MB per 10k text clips

Instrument these with `os_signpost` intervals around open/query/render, not eyeballs. Add a
performance test target that seeds a synthetic 100k corpus and asserts the p95 budget; that is the
only way the promise survives 12 months of feature work.

---

## 5. Recommended architecture

```
                 ┌─────────────────────────────┐
  ⌘C anywhere ──▶│ PasteboardWatcher           │  250 ms Timer, changeCount compare
                 │  · type filter (concealed…) │  · reads content only on change
                 │  · frontmost app attribution│
                 └──────────────┬──────────────┘
                                │ new clip
                                ▼
                 ┌─────────────────────────────┐
                 │ ClipStore (GRDB or raw C)   │  single writer connection, WAL
                 │  clips / clip_content       │  hash dedupe, bump = delete+insert
                 │  clips_fts (unicode61)      │  rowid == recency
                 └──────────────┬──────────────┘
                                │ read-only connections
        ┌───────────────────────┼────────────────────────┐
        ▼                       ▼                        ▼
  ClipboardPanel          QueryEngine              MaintenanceQueue
  (NSPanel, non-          (debounced 120 ms,       (evict, vacuum,
   activating,             coalesced, cancelled,    orphan sweep — off
   table view,             LIMIT 50, two-step       the main thread,
   keyboard-first)         id-fetch)                after first paint)
```

`Glimpse`→ no. Keep it boring: **AppKit** (`NSPanel` + `NSTableView`), **Swift 6**, **SQLite via
GRDB** (best-in-class FTS5 + migration + concurrency story; SwiftData cannot do FTS5, and Core Data
would force an in-memory fetch to filter, which is the failure mode being fixed).

### 5.1 Schema (validated: triggers, update, delete and `integrity-check` all pass)

```sql
PRAGMA journal_mode = WAL;
PRAGMA synchronous  = NORMAL;
PRAGMA busy_timeout = 5000;

CREATE TABLE clips (
  id          INTEGER PRIMARY KEY,          -- == insertion order == recency. Never reuse, never reorder.
  created_at  REAL    NOT NULL,
  app_bundle  TEXT,                         -- source app for filtering
  app_name    TEXT,
  kind        TEXT    NOT NULL,             -- text | url | code | email | image | file
  hash        BLOB    NOT NULL,             -- SHA-256 of normalized content, for dedupe
  pinned      INTEGER NOT NULL DEFAULT 0,
  byte_size   INTEGER NOT NULL,
  preview     TEXT    NOT NULL              -- first ~500 chars, what the list renders
);
CREATE INDEX clips_app_id ON clips(app_bundle, id DESC);
CREATE INDEX clips_pinned_id ON clips(pinned, id DESC) WHERE pinned = 1;
CREATE UNIQUE INDEX clips_hash ON clips(hash);

-- Full content lives apart from the list so the list query never touches big text.
CREATE TABLE clip_content (
  clip_id INTEGER PRIMARY KEY REFERENCES clips(id) ON DELETE CASCADE,
  text    TEXT
);

CREATE VIRTUAL TABLE clips_fts USING fts5(
  text,
  content='clip_content',                   -- external content: no duplicate storage
  content_rowid='clip_id',
  tokenize='unicode61 remove_diacritics 2'
);
-- + standard ai/ad/au triggers writing 'delete' commands into clips_fts (see appendix)
```

Design notes that came out of measurement (full detail in `docs/storage-research.md`):

- `content='clip_content'` duplicates nothing; the FTS table stores only the index (2 MB / 10k).
- **No `prefix=` option**: it grew the index 2.9× to cut a 2 ms query to 1 ms. Word-prefix queries
  are already 1.5 ms via the normal tokenizer. Not worth it.
- **No trigram index by default**: 2.2× the indexed text (17× our word index) for a *worse* query
  time, and it cannot match queries under 3 characters at all (`'ku'` → 0 rows, verified). Infix
  matching is served by the fallback path in §5.3, or added later if users ask.
- `preview` denormalised into `clips` so the 50-row render never opens `clip_content`.
- `pinned` is a column, not a separate table: pinning is a filter, and a partial index keeps it free.
- **Order by `id`, never by an unindexed `created_at`.** A `created` column with no index turns the
  plain list query into 40–180 ms of full scan + sort; the `id DESC` form is 0.008 ms. If a
  human-readable timestamp ordering is ever needed, index it explicitly.

Three FTS5 traps that will bite during implementation (reproduced, not theoretical):

1. **"database disk image is malformed" is never corruption.** It means the index and the content
   table disagree — e.g. a `DELETE` or `UPDATE` on the content table with no matching trigger. The
   nasty variant is a stolen `UPDATE` that *succeeds* and then fails at `integrity-check`. Always run
   `INSERT INTO clips_fts(clips_fts, rank) VALUES('integrity-check', 1)` in a migration test.
2. **External-content tables reject `REPLACE`.** The dedupe-upsert must be `DELETE` + `INSERT` — which
   is exactly the bump semantics §5.4 wants anyway.
3. Triggers added to an already-populated table **do not backfill**; run `('rebuild')` once after
   creating them. Also: the system `libsqlite3` on macOS 27.0.1 is 3.54.0 with FTS5 compiled in, so
   there is nothing to bundle (re-check if targeting older macOS).

### 5.2 The three query shapes (all measured, all < 1 ms)

```sql
-- A. browse: no query text, newest first (+ optional filters)
SELECT id, kind, app_name, preview, pinned FROM clips
WHERE (:app IS NULL OR app_bundle = :app)
  AND (:kind IS NULL OR kind = :kind)
  AND (:pinnedOnly = 0 OR pinned = 1)
ORDER BY id DESC
LIMIT 51;                                    -- 0.41 ms with an app filter at 100k

-- B. search, newest-first. ORDER BY THE FTS TABLE'S rowid. Not rank. Not c.id.
SELECT c.id, c.kind, c.app_name, c.preview, c.pinned
FROM clips_fts f
JOIN clips c ON c.id = f.rowid
WHERE clips_fts MATCH :query
  AND (:app IS NULL OR c.app_bundle = :app)
ORDER BY f.rowid DESC
LIMIT 51;                                    -- 0.04 ms at 100k

-- C. optional "best match" mode, only when the user asks for relevance
... ORDER BY rank LIMIT 50;                  -- 21 ms: acceptable behind a toggle, never as default
```

Verify the plan, do not trust it:

```
sqlite> EXPLAIN QUERY PLAN <query B>;
-- must NOT contain "USE TEMP B-TREE FOR ORDER BY"
```

That single line is the difference between 0.04 ms and 20 ms, and it is invisible in code review.

### 5.3 Search pipeline

```
keystroke ─▶ cancel in-flight ─▶ debounce 120 ms ─▶ build query ─▶ run (background) ─▶ apply if still current
```

1. **Debounce 120 ms**, and cancel the previous task on each keystroke. (Maccy debounces 200 ms but
   does not cancel; the debounce is what saves it, not the search.)
2. **Query building is a security boundary.** User input must be neutralised or FTS5 throws:
   `col:val` → `no such column: col`; `(` → syntax error; `"unclosed` → unterminated string.
   Correct and validated approach: wrap each token as a quoted phrase with doubled internal quotes,
   then append `*` outside the quotes for prefix matching.

   ```swift
   func fts5PrefixQuery(_ raw: String) -> String? {
     // split on punctuation too, so "a:b", "^one", "it's" cannot smuggle FTS5 syntax
     let tokens = raw.lowercased()
       .components(separatedBy: CharacterSet.alphanumerics.inverted)
       .filter { !$0.isEmpty }
     guard !tokens.isEmpty else { return nil }
     return tokens.enumerated().map { i, tok in
       let safe = tok.replacingOccurrences(of: "\"", with: "\"\"")
       return i == tokens.count - 1 ? "\"\(safe)\"*" : "\"\(safe)\""   // `*` must be OUTSIDE the quotes
     }.joined(separator: " ")
   }
   ```
   Verified outputs: `kube` → `"kube"*` · `kuber doc` → `"kuber" "doc"*` · `AND` → `"and"*` ·
   `a:b` → `"a" "b"*` · `col:val`, `(`, `"unclosed`, `3*4`, `NEAR` all become literal searches
   instead of throwing. Note `MATCH '"x thr*"'` (star inside the quotes) silently misbehaves — the
   tokenizer eats it. Implicit AND means `it's` → `"it" "s"*` requires both terms; join with `OR`
   for any-term semantics (still injection-safe).

3. **Empty results ⇒ fallback, in this order**: (a) retry as substring `LIKE '%token%'` with `LIMIT`
   (36–49 ms at 100k — run async, show a subtle "searching all history…" state); (b) only if the user
   enabled "fuzzy", run a bounded Fuse pass over the *first page* of candidates rather than the whole
   corpus. Never let fuzzy be the primary path: its cost grows with corpus size and its ranking is
   surprising.
4. **`LIMIT 51`** (fetch one extra to know whether to show "load more"), keyset pagination on
   `id < lastIdDesc`. Offset pagination is fine at these sizes but keyset is free here.
5. **Count is optional.** `COUNT(*)` of matches costs 0.7 ms; if the UI needs "1,284 matches", run it
   only after the result list has already painted, or skip it entirely (most users do not need it).

### 5.4 Write path

```swift
// one transaction
if let existing = try store.clip(withHash: h) {
    // bump semantics: delete + insert so the rowid moves to the top.
    // Update-in-place would need a sortable recency column and would break free rowid ordering.
    try store.delete(id: existing.id)
}
try store.insert(clip)                     // ~tens of µs; rowid = new recency
```

Dedupe hash = SHA-256 of normalised text (trimmed, trailing whitespace collapsed). Store the raw text
separately so dedupe never mutates what gets pasted.

**Eviction**: count-based cap (default 5,000–10,000; the storage math above makes 10k ≈ 12 MB), in the
background, batched into one transaction, triggered at cap + 5% rather than per insert:

```sql
BEGIN IMMEDIATE;
DELETE FROM clips WHERE id IN (
  SELECT id FROM clips WHERE pinned = 0 ORDER BY id ASC LIMIT 2000
);                                            -- 2,000 rows in ~182 ms (91 µs/row)
COMMIT;
```
`pinned = 0` in the victim query is not optional — without it users lose saved clips. Delete spilled
blob files *after* the commit, or a rollback leaves dangling references.

**Do not enable `auto_vacuum`.** Measured over 40% table churn: the file grew 1.5% and
`incremental_vacuum` had zero pages to reclaim. The real maintenance is FTS b-tree merging
(`VALUES('merge', 8)` periodically, `VALUES('optimize')` when idle — this is what keeps queries from
degrading, not vacuum). Run a full `VACUUM` only when the user *lowers* the history cap.

### 5.5 Images (add later, deliberately)

Images are where clipboard managers most often bloat and slow down, so they are a deliberate phase 2.
When added (detail in `docs/storage-research.md` §3):

- **Budget image history in bytes, not items.** Raw screenshots are ~400 KB, so 50k of them is 20 GB;
  256 px thumbnails at ~12 KB are 0.6 GB. Two separate caps (`maxTextClips`, `maxImageBytes`).
- Dedupe on **SHA-256 of the raw pasteboard bytes**, never of a re-encoded `CGImage` (re-encoding is
  not stable across OS versions and silently defeats dedupe).
- Thumbnails belong in a SQLite `thumb` table (8–16 KB rows, one pread, same page as the list query).
  Dozens of thumbnails as separate files means hundreds of `open`/`close` per scroll.
- Generate thumbnails off the paste path with `CGImageSourceCreateThumbnailAtIndex` +
  `kCGImageSourceThumbnailMaxPixelSize` (decodes at reduced size), `NULL` until filled.
- Spill full blobs above ~1 MB to files so `VACUUM` never becomes a multi-minute stall; keep the row.
- Optional OCR: `VNRecognizeTextRequest` on a background queue, into its **own** FTS column weighted
  down via `bm25(clips_fts, 5.0, 1.0)` and capped at ~2k chars — OCR prose is noisy and inflates the
  index. (OCR latency is unverified; measure with a signpost before promising it.)
- Ship text-only first.

### 5.6 UI/UX spec

- **`NSPanel`**, `.nonactivatingPanel`, floating, no title bar, ~420×560, appears under the menu-bar
  icon or at the mouse; dismisses on Escape, on click-outside, and on paste.
- Single-column `NSTableView` with variable-height cells: 1–3 lines of the clip, source app icon at
  the leading edge, kind badge, relative time trailing. `⌘`-number badge on the first ten rows.
- Search field **focused on open** — typing is the first action, not a mode.
- Filter chips above the list (source app, kind, pinned) that compose with the query text.
- Keys: `↑↓` move, `Enter` copy+paste+close, `⌘Enter` copy only, `⌥Enter` paste as plain text,
  `Space` Quick Look, `⌘D` delete, `⌘P` pin, `⌘1…0` instant paste.
- Empty state that teaches: what is recorded, what is excluded, and how to grant pasteboard access.
- The v1 status item should show a **count-less paperclip** exactly like CopyClip: the appeal of the
  incumbent is that it is invisible until needed.

---

### 5.7 Paste path (⌘V synthesis)

```swift
guard AXIsProcessTrustedWithOptions(nil) else { copyOnlyAndShowHint(); return }

let source = CGEventSource(stateID: .combinedSessionState)
source?.setLocalEventsFilterDuringSuppressionState(
  [.permitLocalMouseEvents, .permitSystemDefinedEvents],
  state: .eventSuppressionStateSuppressionInterval)          // otherwise the chord is eaten

let key = keycodeForQWERTY_V()                               // force QWERTY if layout is "Dvorak – QWERTY ⌘"
let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true)
let up   = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
down?.flags = [.maskCommand, .maskNonCoalesced, modifierFlag0x000008]
up?.flags   = down?.flags
down?.post(tap: .cgSessionEventTap)
up?.post(tap: .cgSessionEventTap)
```

Order matters: write the pasteboard, set our own marker type so the watcher does not record the
replay as a new clip, re-stamp `.source` with the original app id, *then* post the event. Re-check
`AXIsProcessTrusted` on every paste, not once at launch — the grant is revoked by macOS updates.

---



**v1 (the "fast CopyClip" people switch for)** — hotkey panel, incremental search (word-prefix),
newest-first list, `Enter` paste, `⌘1–0`, pin, source-app + kind filters, ignore password managers,
configurable retention, launch at login, pasteboard-permission onboarding.

**v1.5** — plain-text paste, Quick Look, edit clip, source-app exclusions UI, themes, per-app rules,
"search all history" fallback, snippet library (named saved clips — the #2 unmet need in reviews).

**v2** — sync (iCloud/iCloud Drive file, not CloudKit-private-only), image history with OCR, export
(JSON/Markdown), automation (URL scheme / Shortcuts / CLI), "paste stack" for multi-item paste.

**Explicitly out of scope for v1**: cloud sync, AI summarisation, team sharing, browser extension.
Each pulls focus from the one thing that wins: latency.

---

## 7. Risks

| Risk | Impact | Mitigation |
|---|---|---|
| Pasteboard privacy alert ships and turns on (see §0/§2.1) | First-run permission wall; worst case, per-read prompts kill background recording | Onboarding that asks on an explicit user action, not on launch. Fallback mode: record only while the panel is open. `NSPasteboard.accessBehavior` is get-only — there is no entitlement or Info.plist key to pre-empt it, so the mitigation is UX, not code |
| OS built-in history improves (snippets, filters) | Erodes the "simple" tier further | Compete on speed + filters + privacy controls, not on "we remember 15 things" |
| App Review scrutiny of accessibility/auto-paste | Ship delay | Ship `Enter`-paste first, auto-paste as an opt-in with graceful fallback |
| Perf regression over time | The one promise breaks | Seed-corpus perf test with p95 budgets in CI (§4.5) |
| The fast `ORDER BY f.rowid DESC` plan is *measured*, not a documented FTS5 guarantee | A future SQLite upgrade could silently reintroduce the 20 ms sort | Assert `EXPLAIN QUERY PLAN` contains no `TEMP B-TREE` and assert p95 latency in the test suite |
| Complexity creep from "rich features" | Same disease as competitors | Every feature must not touch the hot path: browsing/searching stays one indexed query |

---

## 8. Build plan

| Phase | Deliverable | Est. |
|---|---|---|
| 0 | Menu-bar shell, pasteboard watcher (250 ms), SQLite schema, insert/dedupe | 1 day |
| 1 | Panel UI + list render + keyboard nav + `Enter` paste (copy-only fallback) | 1–2 days |
| 2 | Search: debounce/cancel, FTS5 query builder + escaping, `ORDER BY f.rowid DESC`, filters | 1 day |
| 3 | Perf harness: 100k seed corpus, signposts, p95 assertions, `EXPLAIN` check | 0.5 day |
| 4 | Settings (retention, hotkey, exclusions), launch-at-login, pinning, snippet library | 1–2 days |
| 5 | Permission onboarding (pasteboard TCC, Accessibility), polish, empty states | 1 day |
| 6 | Signing, notarization/App Store metadata, screenshots, TestFlight | 1 day |

A competent single developer gets a genuinely fast, shipped v1 in **~1 week of focused work**, with
the perf contract from §4.5 enforced from day 3 onward.

---

## Appendix A — validated SQL

```sql
-- External-content FTS sync (insert/update/delete all verified, integrity-check passes)
CREATE TRIGGER clips_ai AFTER INSERT ON clip_content BEGIN
  INSERT INTO clips_fts(rowid, text) VALUES (new.clip_id, new.text);
END;
CREATE TRIGGER clips_ad AFTER DELETE ON clip_content BEGIN
  INSERT INTO clips_fts(clips_fts, rowid, text) VALUES ('delete', old.clip_id, old.text);
END;
CREATE TRIGGER clips_au AFTER UPDATE ON clip_content BEGIN
  INSERT INTO clips_fts(clips_fts, rowid, text) VALUES ('delete', old.clip_id, old.text);
  INSERT INTO clips_fts(rowid, text) VALUES (new.clip_id, new.text);
END;

-- Sanity check after any schema change / migration:
INSERT INTO clips_fts(clips_fts) VALUES ('integrity-check');
INSERT INTO clips_fts(clips_fts) VALUES ('rebuild');   -- full rebuild, ~5 s per 100k
```

## Appendix B — reproducible benchmarks

- `benchmarks/fts5_bench.py` — builds the 100k corpus, prints index sizes and the latency table;
  asserts that the "fast" queries stay under 5 ms and that the slow shapes reproduce.
- `benchmarks/memscan_bench.swift` — the in-memory Swift comparison (String vs UTF-8 bytes,
  5k vs 100k).

Run: `python3 benchmarks/fts5_bench.py && swiftc -O benchmarks/memscan_bench.swift -o /tmp/memscan && /tmp/memscan`

## Appendix C — sources

**Companion document:** `docs/storage-research.md` — the full storage/search deep-dive (validated DDL,
every FTS5 failure mode reproduced, library comparison, instrumentation, 10 explicitly-unverified
items). Read it before implementing §5.

- Maccy source (architecture evidence): https://github.com/p0deje/Maccy — `Search.swift`,
  `Observables/History.swift`, `Clipboard.swift`, `Storage.swift`
- Pasteboard privacy preview status + every revision: https://mjtsai.com/blog/2025/05/12/pasteboard-privacy-preview-in-macos-15-4/
- Apple's announcement (still "an upcoming feature"): https://developer.apple.com/documentation/updates/appkit
- `NSPasteboard.accessBehavior`: https://developer.apple.com/documentation/appkit/nspasteboard/accessbehavior-swift.enum
- Pasteboard type spec: https://nspasteboard.org
- KeePassXC's non-standard concealed type: https://github.com/keepassxreboot/keepassxc/blob/develop/src/gui/Clipboard.cpp
- Carbon global hotkeys (sandbox/MAS-safe): https://github.com/sindresorhus/KeyboardShortcuts
- Auto-paste + Accessibility, from a shipping MAS app: https://pasteapp.io/help/paste-directly-to-other-applications
- `SMAppService`: https://developer.apple.com/documentation/servicemanagement/smappservice
- Built-in clipboard history in macOS 26: https://www.macobserver.com/tips/how-to/use-clipboard-history-on-macos-tahoe/
- `kTCCServicePasteboard`: verified locally in `/System/Library/PrivateFrameworks/TCC.framework/Support/tccd` (macOS 27.0.1, build 26A434); `accessBehavior` read `.alwaysAllow` (2) from a compiled probe on the same machine
- App Store pricing/ratings: iTunes lookup API (`itunes.apple.com/lookup?id=…`), Nov 2026
- SQLite FTS5: https://sqlite.org/fts5.html
