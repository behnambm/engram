# Persistence & Search Layer for a Native macOS Clipboard Manager

Research brief for 100k+ clips, multi-KB text, live search-as-you-type.

## 0. Method, environment, and what is measured vs. assumed

**Measured** on this machine (macOS 27.0.1, arm64, SQLite **3.54.0** — both `/usr/bin/sqlite3`
and the system `libsqlite3` are 3.54.0), 100,000 synthetic clips with a heavy-tailed size
distribution (70% 3–40 words, 23% 40–400, 6.5% 400–3000, 0.5% 3000–12000), 142.9 MB raw UTF-8
text. Every number labelled "measured" below is reproducible from the scripts described in §5.

**Verified on the system library** an app actually links:

```
libsqlite3 version: 3.54.0
  FTS5                   OK        <- so an app linking system libsqlite3 gets FTS5 free
  trigram tokenizer      OK        <- and the trigram tokenizer, no bundled SQLite needed
  contentless_delete     OK
  contentless_unindexed  OK
  sqlite3_threadsafe() = 2         <- SQLITE_THREADSAFE=1 (serialized)
```

This is the single most useful deployment fact: **you do not need to bundle SQLite** to get
FTS5 or trigram on current macOS. Verify per-OS if you support older systems (see §7).

**Marked unverified** where I could not measure or did not find a primary source. Nothing below
is a fabricated benchmark.

Sizes are quoted two ways because clipboard corpora vary wildly: as a ratio to indexed text
(the portable number) and per 10k clips for a stated corpus.

| Index | Indexed text | FTS index | Ratio to text | Per 10k clips |
|---|---|---|---|---|
| unicode61, heavy-tail corpus | 142.9 MB | 31.1 MB | **0.22×** | 3.1 MB |
| unicode61, small clips (~100 B) | 10.1 MB | 3.6 MB | **0.36×** | 3.6 MB |
| trigram, heavy-tail corpus | 139.2 MB | 274.4 MB | **1.97×** | 27.4 MB |
| trigram, small clips (~100 B) | 10.1 MB | 23.0 MB | **2.28×** | 23.0 MB |
| porter, heavy-tail corpus | 140.4 MB | 30.7 MB | 0.22× | 3.1 MB |

**Trigram costs 6–9× a unicode61 index**, and roughly 2× the text it indexes. That ratio is
stable across clip sizes; the absolute number tracks total text volume, which is why per-10k
figures range from 2.3 MB (tiny clips) to 27 MB (multi-KB clips).

---

## 1. SQLite FTS5

### 1.1 The four table modes, and what each one breaks

Per the [FTS5 docs, §4.4](https://sqlite.org/fts5.html#external_content_and_contentless_tables),
`content=` selects one of three behaviours. Choose deliberately — this is the setting that
causes almost every FTS5 bug report.

**`content` unset (ordinary FTS5 table).** The text is stored twice: once in the FTS table's
`%_content` shadow table, once in your own table if you keep one. Simplest, most robust, wastes
~1× text. Only sane choice if you have no separate clips table.

**`content=''` (contentless).** Indexes text, stores nothing, so `snippet()`/`highlight()` and
all column reads return NULL (only `rowid` survives). Critically:

- `UPDATE`/`DELETE` are **rejected** — measured: `DELETE FROM f1 WHERE rowid=1` →
  `cannot DELETE from contentless fts5 table: f1`.
- The only removal path is the special `'delete'` command, and it requires you to **replay the
  exact original text**. Measured failure: after
  `INSERT INTO f1(f1,rowid,body) VALUES('delete',2,'completely different words')`, a query for
  the *real* content `f1('gamma')` **still returned rowid 2** — stale entries survive, silently,
  with no error. This is the corruption mode people hit.

**`content=''` + `contentless_delete=1` (SQLite ≥ 3.43).** Measured working: `DELETE` and
`INSERT OR REPLACE` both behave normally, deleted rows stop matching, `integrity-check` passes.
Tombstones accumulate in the b-trees and are cleared at merge time (see §1.6). The docs say
plainly: *"Unless backwards compatibility is required, new code should prefer contentless-delete
tables to contentless tables."* Use this if you need index-only storage.

**`content='clips'` (external content).** The FTS table stores only the index and reads column
values on demand from `clips` via
`SELECT <content_rowid>, <cols> FROM <content> WHERE <content_rowid> = ?`. This is the right
choice for a clipboard manager: no duplicated text, `snippet()`/`highlight()` work, and the
index rebuilds from source of truth with `'rebuild'`. **But the FTS columns must exist as real
columns on the content table** — my first draft used a view that did not exist and the search
silently returned nothing. The `'rebuild'` command is your recovery path.

### 1.2 "database disk image is malformed" — actual root cause, reproduced

This error is the #1 reported FTS5 problem, and it is **almost never physical corruption**. It
means the FTS index and the content table disagree about what row `N` contains. Reproduced
here, from [§4.4.4 "External Content Table Pitfalls"](https://sqlite.org/fts5.html#external_content_table_pitfalls):

```
-- external-content table populated by hand, no triggers
CREATE TABLE clip(id INTEGER PRIMARY KEY, body TEXT);
CREATE VIRTUAL TABLE fts USING fts5(body, content='clip', content_rowid='id');
INSERT INTO fts(rowid, body) VALUES(1,'alpha beta gamma');

DELETE FROM clip WHERE id=1;        -- content row leaves; index entry stays

SELECT rowid, body FROM fts('alpha');
--  Error: fts5: missing row 1 from content table 'main'.'clip'

INSERT INTO fts(fts, rank) VALUES('integrity-check', 1);
--  Error: database disk image is malformed      <-- exactly this message
```

A second, even easier-to-hit variant: **`UPDATE` with no update trigger.**

```
UPDATE clip SET body='totally new words here' WHERE id=5;   -- succeeds
INSERT INTO fts(fts, rank) VALUES('integrity-check', 1);
--  Error: database disk image is malformed
```

The `UPDATE` reports success. The index still contains the old tokens. Nothing tells you until
a query returns a row whose text no longer matches — and the only reliable detector is
`integrity-check` with `rank=1`, which compares the index against the content table.

Two more documented traps, both confirmed in the docs:

- The `'delete'` command's column values must equal what is currently in the table: *"If the
  values 'inserted' into the text columns as part of a 'delete' command are not the same as
  those currently stored within the table, the results may be unpredictable."*
- External-content tables **do not support `REPLACE` conflict handling** (handled as `ABORT`).
  So dedupe-by-`INSERT OR REPLACE` does not work here — use explicit `DELETE` then `INSERT`.
- Creating triggers on an already-populated table does **not** backfill the index. You must
  `'rebuild'`.

From the SQLite forum, changing `content_rowid` later is also called out as corrupting:
*"changing the column designated as content_rowid will result in a corrupted database."*

### 1.3 The correct trigger + delete + rebuild pattern

Three triggers, all three operations, and `old.*` passed verbatim. This exact DDL was validated
end to end: insert → search → update → delete → `integrity-check(1)` → **PASS**.

```sql
CREATE VIRTUAL TABLE clip_fts USING fts5(
  preview, ocr,
  content='clip', content_rowid='id',
  tokenize="unicode61 remove_diacritics 2"
);

CREATE TRIGGER clip_ai AFTER INSERT ON clip BEGIN
  INSERT INTO clip_fts(rowid, preview, ocr)
    VALUES (new.id, new.preview, new.ocr);
END;

CREATE TRIGGER clip_ad AFTER DELETE ON clip BEGIN
  INSERT INTO clip_fts(clip_fts, rowid, preview, ocr)
    VALUES ('delete', old.id, old.preview, old.ocr);
END;

-- AFTER UPDATE OF <indexed cols> only: avoids reindexing on pinned/created bumps
CREATE TRIGGER clip_au AFTER UPDATE OF preview, ocr ON clip BEGIN
  INSERT INTO clip_fts(clip_fts, rowid, preview, ocr)
    VALUES ('delete', old.id, old.preview, old.ocr);
  INSERT INTO clip_fts(rowid, preview, ocr)
    VALUES (new.id, new.preview, new.ocr);
END;
```

Repair / maintenance commands:

```sql
-- rebuild the whole index from the content table (after adding triggers, or on repair)
INSERT INTO clip_fts(clip_fts) VALUES('rebuild');

-- verify index matches content table; throws "database disk image is malformed" on drift
INSERT INTO clip_fts(clip_fts, rank) VALUES('integrity-check', 1);

-- drop everything; only for external-content and contentless tables
INSERT INTO clip_fts(clip_fts) VALUES('delete-all');
```

`integrity-check` walks every row; it is a debug/upgrade-time tool, not a launch-time one.
Cheap startup heuristic: compare `SELECT count(*) FROM clip` against a stored count, and run
`'rebuild'` on the upgrade that introduces FTS.

### 1.4 Tokenizers

- **`unicode61`** (default). Unicode 6.1 word segmentation, case-insensitive, diacritics
  removed by default (`remove_diacritics 0|1|2`; `2` is the modern, stricter removal).
  Indexes whole words → fast, compact, **prefix queries only**. Cannot find `ubernet` inside
  `kubernetes`.
- **`porter`**. unicode61 + English stemming (`databases` matches `database`). Measured index
  size identical to unicode61 (30.7 vs 31.1 MB). Harmless for prose, mildly wrong for code,
  hashes, and identifiers — which is most of what people copy. **Not recommended** here.
- **`ascii`**. Treats all non-ASCII as token characters. Only useful as a fast path when you
  know the text is ASCII; pointless for a general clipboard.
- **`trigram`** (SQLite ≥ 3.34). Indexes every 3-character sequence, giving true substring
  search. This is the tokenizer that makes infix "as you type" possible.

**Trigram specifics**, from [§4.3.4](https://sqlite.org/fts5.html#the_trigram_tokenizer):

- Supports general substring `MATCH`: `SELECT * FROM tri('cdefg')` matches `abcdefghij`.
- Also makes `LIKE '%...%'` and `GLOB` use the index — *unless* `remove_diacritics` is set, and
  never for `LIKE` with an `ESCAPE` clause.
- `case_sensitive 1` → case-sensitive matching, but then **only `GLOB` is indexed, not `LIKE`**.
  `case_sensitive 1` with `remove_diacritics 1` is an error.
- **Queries shorter than 3 unicode characters match nothing.** Measured and confirmed: `'ku'`
  and `'k'` returned **0 rows**; `'kub'` returned 42,646. This is the defining UX constraint —
  the first two keystrokes of every search are blind.
- 3-char minimum applies to full-text queries; a `LIKE`/`GLOB` pattern with no 3-char literal
  run falls back to a full table scan.
- `detail=none`/`detail=column` shrink the index a lot but then *full-text tokens longer than 3
  characters are not allowed* — only viable if the index exists purely for `LIKE`/`GLOB`.

**Practical resolution of the 3-char gap** (measured): on the unicode61 index, short prefix
queries are cheap when ordered by rowid descending — `'k*'` p50 **1.30 ms**, `'ku*'` **1.06 ms**,
`'kub*'` **1.00 ms**, all returning 50 rows. So:

- Use **unicode61 prefix queries** for 1–2 characters (covers the keystroke gap).
- Optional second trigram index for ≥3 characters if infix matters, at 2× text size.
- Or accept prefix-only matching. For a clipboard manager this is usually enough, and it is
  10× smaller. Recommend this as the default.

### 1.5 Prefix indexes (`prefix='2 3'`) — measured, and not worth it

[§4.2](https://sqlite.org/fts5.html#prefix_indexes): a prefix query without one is a *range
scan* of all tokens between `abc` and `abd`. A prefix index records short prefixes explicitly.

Measured on the same 100k corpus, same building pattern:

| Config | FTS index | Build time | `MATCH 'kuber*'` p50 |
|---|---|---|---|
| no prefix index | 31.1 MB | 4.7 s | 1.99 ms |
| `prefix='2 3'` | **89.1 MB** (2.9×) | 7.8 s | 1.00 ms |
| `prefix='2 3 4'` | **115.9 MB** (3.7×) | 9.3 s | 0.98 ms |

**2.9× the index for a 2× speedup on a query that already returns in 2 ms.** With
`ORDER BY rowid DESC LIMIT 50` the range scan early-exits anyway. Skip prefix indexes entirely;
they only pay off for prefix-heavy workloads on huge token vocabularies.

### 1.6 Ranking and highlighting

`bm25()` returns a *negative* score (better = smaller) so that default ascending sort is
best-first. `ORDER BY rank` is equivalent to `bm25()` with no weights but faster because it can
early-exit — although, see §1.7, both are far too slow to use for interactive search.

```sql
-- column weights: preview matters 5x, ocr 1x
SELECT rowid FROM clip_fts
 WHERE clip_fts MATCH ?
 ORDER BY bm25(clip_fts, 5.0, 1.0)
 LIMIT 50;
```

`snippet()` selects the best fragment; `highlight()` returns the whole column marked up.
Measured over 50 result rows: **`snippet()` 0.70 ms, `highlight()` 0.76 ms.** Both cheap enough
to call on the visible page only — do not call them on the full match set.

```sql
SELECT snippet(clip_fts, 0, '[', ']', '…', 12) AS frag
  FROM clip_fts WHERE clip_fts MATCH ? ORDER BY rowid DESC LIMIT 50;
```

`snippet()`'s token-count argument must be 1…64. Markup here is ASCII brackets, not HTML — this
is an AppKit app, so emit attributed ranges rather than HTML tags.

### 1.7 Search-as-you-type ordering — the finding that dominates everything

`LIMIT 50` does **not** save you when you sort by rank. BM25 needs corpus-global IDF, so every
matching row is scored before the first row is emitted. With a high-frequency term (~42k matches
out of 100k) the costs measured were:

| Query shape (all `LIMIT 50`) | p50 |
|---|---|
| `MATCH 'the'` **no ORDER BY** | **0.01 ms** |
| `MATCH 'the' ORDER BY f.rowid DESC` | **0.013 ms** |
| `MATCH 'the' ORDER BY rank` | **22.5 ms** |
| `MATCH 'kubernetes' ORDER BY rank` | 24.1 ms |
| `MATCH 'the' ORDER BY c.created DESC` (indexed column) | **41.6 ms** |
| trigram `MATCH 'ubernet'` no sort / `ORDER BY rank` | 0.045 ms / **50.4 ms** |
| rare term, `ORDER BY rank` (nothing matches) | 0.007 ms |

Same query, ~1,700× difference, caused entirely by the sort clause. `ORDER BY rowid DESC` is
fast because FTS5 doclists are stored in ascending rowid order, so a reverse scan plus `LIMIT`
terminates after 50 rows; joins ordered by a *joined* column force SQLite to materialise and
sort the whole match set (`USE TEMP B-TREE FOR ORDER BY`).

**Design consequence.** Order by `clip_fts.rowid DESC`, and make `rowid` mean "recency":

```sql
SELECT c.id, c.preview, c.created
  FROM clip_fts f JOIN clip c ON c.id = f.rowid
 WHERE f.clip_fts MATCH ?
   AND (? IS NULL OR c.app_id = ?)      -- source app
   AND (? = 0 OR c.kind = ?)            -- content type
   AND (? = 0 OR c.pinned = 1)          -- pinned only
   AND c.created >= ?
 ORDER BY f.rowid DESC
 LIMIT 50;
```

Measured with an app filter added: **0.050 ms**. `EXPLAIN QUERY PLAN` confirms it is a
`SCAN f VIRTUAL TABLE` plus `SEARCH c USING INTEGER PRIMARY KEY` — no temp b-tree.

> **Caveat, mark this.** Fast reverse-rowid scan is *measured on 3.54.0* but is **not a
> documented ordering guarantee**. Pin it with a regression test that asserts both the plan and
> the p50, and re-benchmark on OS upgrades. Fallback if it ever degrades: keep `LIMIT` without
> `ORDER BY` and page in application code, or maintain a separate recency table.

Corollary that is easy to miss: **you cannot bump a clip to the top by `UPDATE`**, because
`UPDATE` keeps the rowid. Bumping must be `DELETE` + `INSERT` to mint a new rowid. That is also
the only way to store a session-based "last used" without breaking this ordering.

Pagination:

```sql
-- keyset on created, measured 0.008 ms per page
SELECT id FROM clip WHERE created < ? ORDER BY created DESC LIMIT 50;
```

Keyset stays flat (0.008 ms); `OFFSET 90000` measured 0.304 ms — 38× worse and growing. Use
keyset. Note keyset needs an index: without `clip(created)`, `ORDER BY created DESC LIMIT 50`
measured **40–180 ms** (full scan + sort). This is the other easy catastrophic mistake — the
plain "show me recent clips" list must be an index scan.

### 1.8 Escaping user input for MATCH

FTS5 query syntax has operators (`AND`, `OR`, `NOT`, `NEAR`, `+`, `*`, `^`, `-`, `col:`), and a
bareword may only contain alphanumerics, `_`, and non-ASCII. Raw user text is a syntax-injection
bug: typing `AND` raises `syntax error near "AND"`, `foo:bar` raises `no such column`, and a
lone `"` is worse.

Two safe strategies.

**(a) Structured: split into terms, quote every term.** Recommended for search-as-you-type.

```swift
/// Builds a safe FTS5 query from raw user input as an implicit-AND of prefix terms.
/// Returns nil when there is nothing searchable (caller should skip FTS entirely).
func fts5PrefixQuery(_ raw: String) -> String? {
    let tokens = raw.lowercased()
        .components(separatedBy: CharacterSet.alphanumerics.inverted)
        .filter { !$0.isEmpty }
    guard !tokens.isEmpty else { return nil }
    return tokens.enumerated().map { i, tok in
        // double any embedded quote (defence in depth; splitting already removed them)
        let safe = tok.replacingOccurrences(of: "\"", with: "\"\"")
        // '*' must be OUTSIDE the quotes, or the tokenizer eats it
        return i == tokens.count - 1 ? "\"\(safe)\"*" : "\"\(safe)\""
    }.joined(separator: " ")
}
// "kuber doc" -> "\"kuber\" \"doc\"*"   (only the last term gets prefix handling)
// "AND"       -> "\"and\"*"        (quoted: never parsed as an operator)
// "a:b"       -> "\"a\" \"b\"*"
// ""          -> nil
```

Verified output (note the implicit-AND behaviour): `"kube"` → `"kube"*`; `"kuber doc"` →
`"kuber" "doc"*`; `"AND"` → `"and"*`; `"a:b"` → `"a" "b"*`; `"^one"` → `"one"*`; `""` and
`"*"` → nil. Two consequences worth knowing:

- Splitting on punctuation turns one CJK/compound input into several terms, and implicit AND
  means **all** of them must match. `"inv-4471"` → `"inv" "4471"*` (good), but `"it's"` →
  `"it" "s"*` (the trailing `s` is now required). If that feels too strict, join with ` OR `
  instead of whitespace for any-term semantics — still fully quoted, so still injection-safe.
- Non-ASCII survives intact (`"héllo"`, `"wörld"`), because `CharacterSet.alphanumerics` is
  Unicode-aware. This is why unicode61 is the right tokenizer here.

This is exactly what GRDB's `FTS5Pattern(matchingAllPrefixesIn:)` does for you if you use GRDB
(see §2.1) — it *"build[s] a valid pattern from any string, including strings provided by users"*.

**(b) Validate raw syntax when the user is writing advanced queries.** Use GRDB's
`db.makeFTS5Pattern(rawPattern:forTable:)`, which parses against the real grammar and column
names and throws `DatabaseError` — don't hand-roll a grammar.

The `*` placement is a documented trap: `MATCH '"one two thr*"'` *"may not work as expected"*
because `*` inside quotes is handed to the tokenizer. Always `"term"*`.

For a **trigram** index the escaping is the same, but semantics differ — the whole input is one
substring phrase, not per-word terms, and you must skip FTS below 3 characters:

```swift
func trigramQuery(_ raw: String) -> String? {
    guard raw.count >= 3 else { return nil }   // hard FTS5 limit: <3 chars matches nothing
    return "\"" + raw.replacingOccurrences(of: "\"", with: "\"\"") + "\""
}
```

### 1.9 WAL, pragmas, concurrency for a single-process app

```sql
PRAGMA journal_mode = WAL;      -- one writer, many concurrent readers
PRAGMA synchronous  = NORMAL;   -- durable across app crash; only at risk on OS/power loss
PRAGMA busy_timeout = 5000;     -- ms; wait instead of failing SQLITE_BUSY
PRAGMA foreign_keys = ON;       -- off by default; needed for blob/thumb cascades
```

Measured single-clip capture cost (WAL + `synchronous=NORMAL`, one commit per clip, 100k-row
DB) — capture is never the bottleneck:

| Clip size | p50 | p95 | max |
|---|---|---|---|
| ~60 chars | 0.047 ms | 0.118 ms | 0.22 ms |
| ~1.2 KB | 0.079 ms | 0.376 ms | 6.88 ms |
| ~12 KB | 0.12 ms | 0.40 ms | 4.33 ms |
| ~60 KB | 0.36 ms | 0.75 ms | 5.28 ms |

Concurrency: `sqlite3_threadsafe() == 2` on the system library means serialized mode, so
connections are internally mutexed — but **do not share one connection's transactions across
threads**. The boring, correct shape for this app:

- **One writer connection**, confined to a dedicated serial `DispatchQueue` (or GRDB's
  `DatabaseQueue`). All inserts, deletes, evictions, and `optimize` calls go through it.
- **A small read pool** (`DatabasePool`, or 2–3 read connections) for search. WAL lets these
  read the last committed snapshot without blocking the writer.
- Never `sqlite3_open` on the main thread *and* query on a background queue.
- Poll the pasteboard on a timer (Maccy defaults to a configurable interval, `clipboardCheckInterval`)
  or use `NSPasteboard.changeCount`; either way, hand the captured bytes to the writer queue
  and return immediately.

### 1.10 Storing large text; spilling to files

- Keep text in a `TEXT` column. SQLite reads large values without materialising past the needed
  page only when the column is *not* selected — so `SELECT id, preview` for lists, and fetch
  `body` only for the previewed rows. This matters more than any micro-tuning: selecting `body`
  for 50 rows of multi-KB text is where list rendering actually costs.
- Blobs: for images, store bytes as a `BLOB` column in a *separate* `blob` table, not in `clip`.
  Keeping `clip` rows narrow keeps the hot list/search queries on narrow rows. Do not use
  SQLite's incremental blob I/O for thumbnails — the complexity is unjustified at these sizes.
- **Spill to files** when a single clip exceeds ~1 MB, or when total BLOB bytes would dominate
  the DB. Write to `~/Library/Application Support/<app>/blobs/<sha256-prefix>/<sha256>`, keep
  `body_path`/`blob.path` in SQLite, and never store the same bytes twice (the hash is the path).
  Files also make eviction trivial (`unlink`) and keep `VACUUM` cheap.
- Threshold reasoning: below ~1 MB, a BLOB costs one or two overflow pages and reads in one
  `pread`; a file costs an extra `open`/`close` and a directory entry. Above ~1 MB, the DB grows
  past what `VACUUM` can rewrite without a visible stall, and you lose the ability to reclaim
  space without a full rewrite. (Threshold is a judgement call, **not measured here**.)

### 1.11 auto_vacuum / incremental_vacuum — measured: you don't need it

A clipboard manager evicts old clips forever, so bloat is a reasonable worry. It is not a real
problem: SQLite reuses freed pages, and a capped-size database reaches steady state.

Measured, 100k rows, then 20 rounds of *delete the 2,000 oldest + insert 2,000 new* (40,000 rows
of churn, 40% of the table):

| Strategy | After 100k inserts | After 20 churn rounds | After `incremental_vacuum` |
|---|---|---|---|
| `auto_vacuum=NONE` (default) | 398.4 MB | **404.4 MB** (+1.5%) | n/a |
| `auto_vacuum=INCREMENTAL` | 398.9 MB | **404.9 MB** (+1.5%) | 404.9 MB (**0 free pages**) |

Churn grew the file by 1.5% and `incremental_vacuum` had literally nothing to reclaim.
**Recommendation: leave `auto_vacuum` off.** It adds page-move overhead on every commit for no
benefit at steady state. Run a one-off `VACUUM` only when the cap is *lowered* (a real shrink).

What *does* degrade under churn is the FTS index, not file size. Every delete/update leaves
either a tombstone or an orphaned segment, and queries merge more b-trees. From the SQLite
forum, a real report at scale — [FTS5 Search Performance Deteriorating Quickly](https://sqlite.org/forum/forumpost/d1683a5171):

> *"I have a contentless_delete FTS index with a hair over one million rows in it… my test query
> went from 0.13s to 0.24s"* in 70 minutes, caused by ~6,000 `REPLACE INTO`s per hour.

Dan Kennedy (FTS5's author) confirmed in the same thread that `REPLACE` and `UPDATE` *"both use
the same mechanism. A tombstone by default, or by actually removing the old entries from the
index if secure-delete is turned on."*

Maintenance, then, is about merging, not vacuuming:

```sql
-- incremental merge of a few b-trees; cheap, safe to call often
INSERT INTO clip_fts(clip_fts, rank) VALUES('merge', 8);

-- full merge; does real work proportional to index size — run when idle
INSERT INTO clip_fts(clip_fts) VALUES('optimize');
```

Tuning knobs if churn is high: `automerge` (default 4, max 16; lower = faster queries, slower
writes), `crisismerge` (default 16), `deletemerge` (default 10% — percentage of tombstoned rows
that make a b-tree merge-eligible; only used by contentless-delete tables):

```sql
INSERT INTO clip_fts(clip_fts, rank) VALUES('automerge', 8);
INSERT INTO clip_fts(clip_fts, rank) VALUES('deletemerge', 15);
```

Practical policy: after each eviction batch, run `'merge', 8` if more than N clips were deleted;
run full `'optimize'` on app idle or once per day, wrapped in a signpost. **Do not** run
`optimize` after every insert — measured, it is a no-op on an already-merged index (0 ms) but
costs real time once there is work to do, and it rewrites the index.

For our 100k-scale DB, `optimize` if you ever see it exceed ~1 s: it's proportional to index
size, so it belongs behind an idle check, not on the capture path.

---

## 2. Alternatives

### 2.1 Library choice

| | FTS5 | Migrations | Concurrency | Startup | Binary size |
|---|---|---|---|---|---|
| **Raw C API** | full control | hand-rolled | you own it | fastest | smallest |
| **GRDB.swift** | first-class (FTS3/4/**5**), typed patterns | `DatabaseMigrator`, ordered & idempotent | `DatabaseQueue` / `DatabasePool` (WAL), explicit | low | **unverified** (compiled from source; no published figure) |
| **SwiftData** | **none exposed** | schema versions | `ModelContext`, main-actor biased | higher (schema load) | system framework |
| **Core Data** | none native | `NSMigrationManager` | `NSPersistentContainer`, heavy | highest | system framework |

- **GRDB is the right default here.** It ships `FTS5()` virtual-table support, `FTS5Pattern`
  builders that safely escape untrusted strings (§1.8b), `snippet`/`bm25` helpers, a real
  migrator, and WAL-aware concurrency primitives. It also lets you drop to raw SQL when you need
  the `ORDER BY rowid DESC` trick, which every abstraction above it will fight you on.
- **SwiftData has no FTS5 surface.** Its query path is `#Predicate`/`FetchDescriptor`, which
  compiles to a restricted predicate grammar and raises
  [`SwiftDataError.unsupportedPredicate`](https://developer.apple.com/documentation/swiftdata/swiftdataerror/unsupportedpredicate)
  outside it. There is no `MATCH`, no virtual table. You would be maintaining a parallel raw
  SQLite connection — at which point you have GRDB's complexity with none of its help.
- **Core Data** likewise has no FTS5 support. You can add a virtual table behind a custom
  `NSPersistentStore`, but that is a genuinely advanced, undocumented path.
  *(Marked unverified: I did not find a maintained, production example of FTS5 behind Core Data.)*
- **Startup time** and **binary size** for all four are **unverified** — I found no primary
  measurements and did not build four comparable apps. Ranking above is a reasoned expectation
  from architecture (framework schema loading vs. `sqlite3_open`), not a measurement.

### 2.2 What open-source Mac clipboard apps actually do — Maccy, the reference implementation

Maccy (p0deje/Maccy, the most-starred open-source macOS clipboard manager) is worth reading
because it is the opposite of this brief in two places, and both are instructive:

1. **Storage: SwiftData**, not raw SQLite. `Maccy/Storage.swift` starts `import SwiftData`, uses
   `ModelContainer`/`ModelConfiguration` and `FetchDescriptor`. (It was Core Data — the repo
   still contains `History.xcdatamodeld` — and was migrated.) Its `cleanupOrphanedContents`
   and `removeUnpersistableContents` are exactly the eviction hygiene this brief recommends.
2. **Search: in memory, not FTS.** `Maccy/Search.swift` holds clips in a Swift array and filters
   with [Fuse](https://github.com/krisk/Fuse) (fuzzy), `.regularExpression`, or
   `caseInsensitive` string matching depending on a user-selected mode. There is no SQL
   `MATCH` anywhere. It caps work with `private let fuzzySearchLimit = 5_000` and truncates the
   subject string: *"shortcut to avoid slow search"*.

That second point is the honest state of the art: a popular clipboard manager chose in-memory
search and defends it with a truncation hack. §2.3 shows why that choice does not survive 100k.

Also worth knowing for §3: Maccy's supported pasteboard types are
`.fileURL, .html, .png, .rtf, .string, .tiff`; it ignores `.autoGenerated, .concealed, .transient`;
and it treats `.appleWebArchive` / Safari web archives as unpersistable.

### 2.3 Can a purely in-memory array work at 100k? — measured

Swift 6.4, `swiftc -O`, real `mach_task_basic_info` RSS deltas. Struct of
`{Int64, String, String, Int64, Bool}` plus ~200 bytes of text:

**Memory: 100k clips ≈ 42.8 MB RSS ≈ 449 bytes/clip** (~2.2× the raw text, from `String`
allocation rounding + struct + array storage). For 100k × 200 B — close to 43 MB resident, and
that is *before* thumbnails.

**Latency** for a `kubernetes` substring filter, best of 5:

| Clips | RSS | `localizedCaseInsensitiveContains` | lowercase-copy + `contains` |
|---|---|---|---|
| 10,000 | 6.5 MB | **9.2 ms** | 18.0 ms |
| 50,000 | 26.0 MB | **46.9 ms** | 91.8 ms |
| 100,000 | 32.5 MB | **93.3 ms** | 183.6 ms |

Linear, ~0.93 ms per 10k clips. Note the "optimization" people reach for — precomputing a
lowercased copy — is **2× slower**, because it doubles cache pressure while still allocating on
every `contains`.

Against a 16 ms frame budget (60 fps), the crossover is **~15–20k clips**. At 100k clips,
matching Maccy's approach is **93 ms per keystroke** — roughly six dropped frames, on every
character. That is the argument for FTS5 in one number. (The parent's independent measure of
`String.contains` over 100k landing at 120–200 ms agrees; `memmem` over 5k at 1.0 ms also fits
the linear model.)

`prefix(50)` with no filter is ~0.00 ms, which is why the *initial* popup is always instant and
people believe in-memory search is fine — the cost only appears once they type.

**Verdict:** a pure in-memory approach does not meet a keystroke budget at 100k. It is fine
below ~15k, which is why so many clipboard managers ship it and why they degrade.

### 2.4 Hybrid: recent-N in memory, SQLite for the rest

This is the right architecture, and the measurements say so precisely:

- Keep the **most recent ~2,000 clips** in memory as a `[ClipSummary]` (id, preview, app, kind,
  created, pinned). That is ~1 MB — trivially affordable — and covers most sessions, since users
  overwhelmingly paste something recent.
- Make the **empty query** a pure memory read: **0.00 ms**, so popup open is unaffected by DB
  size.
- On first keystroke, do **not** filter the in-memory array (0.18 ms at 2k, but pointless —
  FTS5 is just as fast and correct). Instead query FTS5 with the **0.013–0.05 ms** path from
  §1.7, which is faster than filtering 2k strings in Swift.
- Use the in-memory array only for (a) the unfiltered initial list, and (b) optimistic UI when a
  clip is added, before the writer commits.

**Perceived speed:** popup open is memory-bound and constant; keystroke-to-results is one FTS5
prefix query plus reading 50 previews from pages that are almost certainly already in the page
cache. Both land well under one frame, so the UI never needs a spinner, a debounce, or a
`Timer` — which is itself the biggest perceptual win, because debouncing is what makes search
*feel* laggy. Add a debounce only if you adopt the trigram index, where a cold page cache can
push a query to tens of ms.

---

## 3. Non-text content

### 3.1 Images: hash dedupe, thumbnails, storage, eviction

**Dedupe by content hash.** `SHA-256` over the raw image bytes (`CryptoKit`'s `SHA256.hash(data:)`),
stored as a 32-byte `BLOB` with a `UNIQUE` index. Hash *before* writing anything: a duplicate
copy then costs one `INSERT` on `clip` and no blob write.

- Hash the **raw pasteboard bytes**, not the decoded `CGImage`. Re-encoding is nondeterministic
  across OS versions and would defeat dedupe.
- Normalize away metadata only if you must dedupe "same image, different PNG encoding" — that
  requires decoding and re-encoding, which costs CPU on the paste path. **Start with raw bytes.**
- Reuse `blob.id` across clips: two clips referencing the same screenshot share one blob row.
  Reference-count by counting `clip` rows, not with a counter column.

**Thumbnails: store in SQLite, in a separate `thumb` table.** A 256 px JPEG is ~8–16 KB encoded
— one or two pages, read in a single `pread`, and it comes back in the same query as the rest of
the row. Splitting thumbnails into files means hundreds of `open`/`close` calls when populating
an image-heavy list, which is strictly worse. Keep full-size bytes in `blob` (or spill to files
above ~1 MB, §1.10).

Generate thumbnails **off the paste path**: insert the clip with `thumb` absent, render a
placeholder, and fill the thumbnail on a background `VNGenerateImageFeaturePrintRequest`-free
path (`CGImageSourceCreateThumbnailAtIndex` with `kCGImageSourceThumbnailMaxPixelSize` is the
cheap way — it decodes at reduced size instead of full-size-then-downsample).

**Size math for a 50k-image history** (arithmetic, not measured):

| Component | Per image | 50k images |
|---|---|---|
| Raw PNG/JPEG blob, typical screenshot | 400 KB | **20 GB** |
| Raw blob, typical small copy | 50 KB | 2.5 GB |
| Thumbnail 256 px JPEG | 12 KB | **0.6 GB** |
| Thumbnail 128 px JPEG | 4 KB | 0.2 GB |
| SHA-256 + row overhead | ~150 B | 7.5 MB |

The raw bytes dominate by 30×. A 50k-image history is a **multi-GB to tens-of-GB** proposition
no matter what you do, which drives three decisions:

1. **Images must be evicted on a byte budget, not a count budget.** 10,000 screenshots can be
   4 GB; 10,000 copied snippets are 2 MB. Use separate caps: `maxTextClips`, `maxImageBytes`.
2. **Thumbnails are the searchable/displayable tier.** Keep thumbnails after evicting the raw
   blob if you want the entry to survive visually — but a 12 KB thumbnail with no underlying
   image is usually worse UX than deletion. Prefer evicting both, oldest-first.
3. **Spill large blobs to files** above ~1 MB so a 20 GB image history does not make `VACUUM`
   a multi-minute stall. The DB then stays small and fast; only the `blobs/` tree is big.

### 3.2 Content-type detection on the macOS pasteboard

Read `NSPasteboard.general` and inspect `pasteboard.types` (`[NSPasteboard.PasteboardType]`,
each a UTI or a private `dyn.*` type). Practical rules:

```swift
// What to look at, in priority order
let supported: Set<NSPasteboard.PasteboardType> = [
    .fileURL, .png, .tiff, .rtf, .html, .string,      // Apple-documented types
]
// Strings that mean "don't record this"
let ignored: Set<NSPasteboard.PasteboardType> = [
    .init("org.nspasteboard.TransientType"),
    .init("org.nspasteboard.ConcealedType"),
    .init("org.nspasteboard.AutoGeneratedType"),
]
// Present on every pasteboard item; means "came from another device" via Handoff
// .init("com.apple.is-remote-clipboard")
```

`NSPasteboard.PasteboardType` has these documented constants
([Apple docs](https://developer.apple.com/documentation/appkit/nspasteboard/pasteboardtype)):
`string, html, rtf, rtfd, png, tiff, pdf, fileURL, URL, fileContents, font, color, sound,
tabularText, multipleTextSelection, ruler, findPanelSearchOptions, collaborationMetadata`, plus
`fileNameType(forPathExtension:)` / `representedPathExtension`. Prefer `.string` when present —
it is what users mean by "copy". Fall back to `.rtf`/`.html` (and extract plain text), then
`.fileURL`, then `.png`/`.tiff`.

Use `NSItemProvider`/`UTType` (`UTType.text`, `UTType.image`, `UTType.conforms(to:)`) when you
have a UTI string and need to classify it, rather than string-matching prefixes.

Two filters that matter in practice and that Maccy implements:

```swift
// vendor-private serialization blobs are noise, not user content
type.rawValue.hasPrefix("dyn.")                      // dynamically registered
type.rawValue.hasPrefix("com.microsoft.ole.source.") // Office paste metadata
```

Also: check `pasteboard.changeCount` against your stored value to avoid double-capture, and set
`org.nspasteboard.source` to your bundle id when *you* put data on the pasteboard, so you do not
record your own paste-back as a new clip.

### 3.3 OCR (Vision `VNRecognizeTextRequest`)

Per [Apple's "Recognizing Text in Images"](https://developer.apple.com/documentation/vision/recognizing-text-in-images):

- Two paths: `.fast` (character detection + small model) and `.accurate` (neural, line-based,
  "much more in line with how humans read"). `.accurate` is the **default**; select `.fast` via
  `request.recognitionLevel = .fast`.
- All processing is **on-device**.
- Set `recognitionLanguages` (order = priority) and `usesLanguageCorrection` (default true).
  Language correction is unsupported for Chinese. Add `customWords` for domain jargon.
- Results are `[VNRecognizedTextObservation]`; take `topCandidates(1).first?.string` per
  observation and join with newlines, or use `boundingBox(for:)` if you need coordinates.
- Pin `revision` (e.g. `VNRecognizeTextRequestRevision3`) for reproducible output — otherwise
  results and cost change with the OS.

**Cost per image: unverified.** I could not measure it: Vision fails in this sandboxed
environment with `nilError` even for a minimal 200×60 image, so I have no honest number. Do not
use a figure from me. My expectation, to be checked — OCR scales with pixel count and is
dominated by model inference, so `.fast` on a 1600×1000 screenshot should be single-digit to
low-tens of milliseconds and `.accurate` several times that, on Apple silicon — but treat that
as a hypothesis and measure it with a signpost (§5) before promising anything in a UI. There is
also a one-time model-load cost on first use per process.

**Run it off the paste path, always.** The paste handler must not block: insert the clip, leave
`ocr` NULL, and enqueue on a serial background queue with `.utility` QoS. Then:

```sql
UPDATE clip SET ocr = ? WHERE id = ?;   -- clip_au trigger reindexes preview+ocr
```

Bound the queue: cancel OCR for clips evicted before they are processed, and skip OCR entirely
for images above a pixel budget (a 6000×4000 photo is not a screenshot).

**Should the FTS index hold OCR text? Yes** — but in its **own column**, so you can weight it
down and so re-indexing readable text does not touch the primary column. `bm25(clip_fts, 5.0,
1.0)` ranks a `preview` hit 5× an `ocr` hit, which is right: OCR text is noisy. Two practical
caveats: OCR output inflates the index substantially (it is unlabeled prose), so cap stored OCR
to the first ~2,000 characters; and mark clips with non-empty `ocr` in the UI so users understand
why a picture matched a text query. Indexing OCR in the same trigram index would be very
expensive — another reason to keep trigram optional.

---

## 4. Dedupe, eviction, sensitive data

### 4.1 Dedupe

- **Text:** SHA-256 over a *normalized* form — trim trailing whitespace, normalize line endings
  to `\n`, collapse runs of >2 blank lines, do **not** lowercase (case is content). Normalizing
  catches the extremely common "copied the same thing twice with a stray newline".
- **Images/files:** SHA-256 over **raw bytes**, no normalization (§3.1).
- Store one 32-byte `hash` column with a `UNIQUE` index for both. Dedupe becomes
  `SELECT id FROM clip WHERE hash = ?` (indexed, microseconds).

**UX: bump vs. insert duplicate.** Both are used in the wild; the right answer is *bump, with
the original body preserved*:

- On duplicate, `DELETE` the old row and `INSERT` a new one with a fresh rowid and `created`
  (§1.7 — `UPDATE` cannot move a row to the top of a rowid-ordered list).
- Keep `pinned` on the bumped row, and keep the original `created` in a separate
  `first_seen` column if you want the "first copied" date for display.
- Do **not** insert literal duplicates. Users read the history list as a set; duplicate entries
  at two scroll positions are the most-complained-about clipboard-manager behaviour.
- Bumping must be a real `DELETE`+`INSERT`, which means it fires `clip_ad`/`clip_ai` and the FTS
  index is correct by construction. Note that external-content tables **reject `REPLACE`**
  (§1.2), so `INSERT OR REPLACE` is not an option — this is a case where the FTS constraint
  enforces the right design.

### 4.2 Eviction — cheap, batched, no stall

Three policies, and you want all three:

| Policy | Limit | Why |
|---|---|---|
| count | `maxClips` (e.g. 100k, or 10k default) | bounds index size and search time |
| byte budget | `maxImageBytes` (e.g. 2 GB) | images are 30× the storage of text (§3.1) |
| age | `maxAgeDays` (e.g. 90), pinned exempt | bounds the long tail nobody scrolls |

Algorithm — never `DELETE` one row at a time on the capture path:

```sql
-- 1. find victims with the recency index; exclude pinned
SELECT id FROM clip
 WHERE pinned = 0
 ORDER BY created ASC
 LIMIT 2000;

-- 2. delete in ONE transaction, batched (measured: ~182 ms for 2,000 deletes
--    + 2,000 inserts in a single transaction; ~91 us/row)
BEGIN IMMEDIATE;
DELETE FROM clip WHERE id IN (SELECT id FROM clip WHERE pinned = 0 ORDER BY created ASC LIMIT 2000);
COMMIT;

-- 3. reclaim file space only if the cap actually shrank (usually: do nothing, §1.11)
-- 4. merge FTS b-trees if the batch was large
INSERT INTO clip_fts(clip_fts, rank) VALUES('merge', 8);
```

Notes that make this not stall:

- **Batch size ~1,000–2,000.** One transaction, one WAL write, one `fsync`-ish. Measured
  **182 ms** for a 2,000/2,000 delete+insert round on a 100k DB — a one-off on a background
  queue, invisible.
- **Run eviction on the writer queue, after the commit that pushed you over the cap**, not on
  the paste path, and not on every insert. Trigger it when count exceeds the cap by a margin
  (e.g. cap + 5%) so it runs once every few thousand captures instead of constantly.
- **`BEGIN IMMEDIATE`**, not deferred: you are definitely going to write, and taking the write
  lock up front avoids a mid-transaction `SQLITE_BUSY` upgrade failure under concurrency.
- **Blob files:** delete the file after the transaction commits. If you delete first and the
  transaction rolls back, you have a row pointing at a missing file. Delete-after also means an
  orphaned file on crash, which a startup sweep of `blobs/` against `blob.sha256` cleans up.
- **Age-based cleanup needs `created` indexed** — it is, via `clip_recent`.
- Pin exemption must be `pinned = 0` in the victim query, or users lose the entries they
  explicitly saved.

### 4.3 Detecting sensitive data

**Tier 1 — trust the markers (cheap, exact, do this always).** From
[nspasteboard.org](https://nspasteboard.org), the universal identifiers and their meanings:

| Marker | Meaning | Action |
|---|---|---|
| `org.nspasteboard.ConcealedType` | confidential — obfuscate on screen, avoid writing plaintext | don't store, or store encrypted + mask in UI |
| `org.nspasteboard.TransientType` | will vanish in seconds | **don't record at all** |
| `org.nspasteboard.AutoGeneratedType` | app-generated, user never pressed Copy | don't record |
| `org.nspasteboard.source` | bundle id of originating app | display/policy only |

Plus the legacy proprietary markers the page lists and asks historians to support:
`de.petermaurer.TransientPasteboardType` (TextExpander/Butler), `com.typeit4me.clipping`,
`Pasteboard generator type` (Typinator), `com.agilebits.onepassword`, and
`com.apple.is-remote-clipboard` (Handoff). Password managers set `ConcealedType`; that single
check covers the highest-risk case, and it is free.

Maccy's default is to ignore all three universal markers, and nspasteboard.org notes exactly
that (its list entry reads *"By default Maccy will ignore: `org.nspasteboard.TransientType`,
`org.nspasteboard.ConcealedType`, and `org.nspasteboard.AutoGeneratedType`"*).

**Tier 2 — heuristics worth implementing (ordered by value/effort).** These only *flag*; the
correct response is to mask in the UI and exclude from the persisted body, never to silently
delete a user's clip.

1. **Entropy + length on a single token** — a 24+ char token with high Shannon entropy and mixed
   character classes is a credential far more often than it is prose. Cheap, language-agnostic,
   and catches unknown vendors. Best single heuristic.
2. **Known key shapes** (high precision, low cost): `AKIA[0-9A-Z]{16}` (AWS),
   `sk-[A-Za-z0-9]{20,}` / `sk-ant-` (OpenAI/Anthropic), `ghp_|gho_|github_pat_` (GitHub),
   `xox[baprs]-` (Slack), `AIza[0-9A-Za-z\-_]{35}` (Google), `-----BEGIN [A-Z ]*PRIVATE KEY-----`
   (always sensitive). A short regex list is worth more than a general detector.
3. **`key=value` / `--flag=secret` pairs** — attribute names matching
   `(password|passwd|secret|token|api[_-]?key|authorization|bearer|private[_-]?key)` with a
   non-trivial value. Catches `.env` and curl lines, which are a huge share of real clipboard
   leaks.
4. **Luhn check + issuer prefix + length 13–19** for credit cards. Precise, ~10 lines, no ML.
5. **Long high-entropy base64/JWT** — three dot-separated base64url segments is a JWT; treat as
   sensitive.
6. **Skip** "is this a password" ML heuristics and dictionary scoring. High false-positive rate
   on code snippets, and a clipboard manager that masks your `kubectl` output is worse than one
   that leaks an API key you copied deliberately.

**Do not** attempt to detect secrets by searching FTS or by writing your own password model. The
markers plus 1–3 above cover the realistic risk at a few dozen lines of code. And make the
behaviour user-visible and configurable ("don't store concealed items" on by default), because
silent data loss is indistinguishable from a bug.

---

## 5. Measuring — so the speed claims are honest

### 5.1 Synthetic corpus with a realistic size distribution

The distribution matters more than the row count: 100k uniform 200-byte clips and 100k
heavy-tailed clips differ by 10× in index size and by 10× in query latency. Use the one from
this brief (parameters in `gen.py`), and **publish the distribution alongside any latency
number**:

| Bucket | Share | Words |
|---|---|---|
| short (URLs, ids, one-liners) | 70% | 3–40 |
| medium (paragraphs) | 23% | 40–400 |
| large multi-KB | 6.5% | 400–3,000 |
| very large (logs, dumps) | 0.5% | 3,000–12,000 |

Generate with a fixed seed, word list sampled from *code and prose*, and dedupe-off (so the
`UNIQUE` hash index is actually exercised). Also generate a **second** corpus of only small
clips — as §0 shows, the trigram index goes from 23 MB to 274 MB across those two corpora, so a
single corpus will mislead you.

### 5.2 Instrumentation

- **`os_signpost`** for popup open, keystroke→results, capture, eviction, `optimize`. Use
  `OSSignposter` (`os.Logger`-based, the current API) with named intervals so Instruments shows
  them as ranges. One signpost pair around the search query is the highest-value measurement in
  the app.
- **XCTest `measure`** for the regressions you care about: `measure(metrics: [XCTClockMetric(),
  XCTMemoryMetric(), XCTStorageMetric()])`. Assert *p50 and p95*, not the mean — a 0.05 ms p50
  with a 300 ms p99 is a broken app.
- **Instruments templates:** *Time Profiler* (where the ms go — expect `swift_string` and
  CoreText, not SQLite, during list rendering), *Allocations* + *Leaks* (memory per clip over a
  long session), *File Activity* (WAL churn, blob writes), *App Launch* (cold start), *Hangs*
  (main-thread stalls — catches the missing-index `ORDER BY` and any accidental `body` select),
  and *SQLite* tracing via `sqlite3_trace_v2` for query-level timing in development.
- **Honesty guards.** Pin the OS version, SQLite version, corpus seed, and page-cache state
  (cold vs warm) with each number — my `ORDER BY created` measurement moved between 40 ms and
  180 ms depending only on page cache. Report warm-cache *and* cold-cache figures; the cold
  number is what users feel on the first search after launch. Discard the first run of any
  query, and report p50/p95/max rather than a best-of-N (the `max` column in §1.9 is the one
  that explains UI hitches).

### 5.3 Targets a clipboard manager should hit

Reasoned budgets, not published claims:

| Metric | Target | Basis |
|---|---|---|
| Popup open → list rendered | **< 50 ms** (warm), < 150 ms cold | one frame is 16 ms; the popup animates, so 1–3 frames is imperceptible |
| Keystroke → filtered results | **< 16 ms p95** | one frame; §1.7 shows 0.01–0.05 ms for the query itself, so budget goes to row decode + layout |
| DB size per 10k clips (text) | **~3 MB** (`unicode61`), ~25 MB (`trigram`) | measured, §0; exclude image blobs entirely |
| Cold start → UI usable | **< 400 ms** | no system figure; schema check + one indexed query is microseconds, so this is all framework/app launch |
| Idle CPU | **≈ 0%** | pasteboard polling at 0.1–0.5 s on `changeCount` is a single integer read; avoid re-reading types when unchanged |
| RSS (idle, 100k clips) | **< 60 MB** | 2k-clip in-memory window (~1 MB, §2.4) + SQLite page cache; must *not* scale with history size |

`idle CPU ≈ 0%` and `RSS independent of history size` are the two properties that most clearly
separate a good clipboard manager from a bad one — both are consequences of the design above
(capped in-memory window, indexed queries, no full materialisation).

**Published claims from real clipboard apps: none found.** I searched and did not locate a
vendor-published latency, memory, or DB-size figure for any macOS clipboard manager (Maccy,
Paste, Alfred, Raycast, iClipboard). So the targets above are engineering budgets and are
**marked as such** — do not cite them as industry benchmarks.

---

## 6. Recommended storage design

Everything below was executed against SQLite 3.54.0 and passes
`INSERT INTO clip_fts(clip_fts, rank) VALUES('integrity-check', 1)` after a full
insert→search→update→delete lifecycle. Hot search path measured at **0.013–0.050 ms**.

**Choices, and why:**

- `rowid` **is** recency (§1.7) → `ORDER BY f.rowid DESC` is 1,700× faster than `ORDER BY rank`.
  Bumping a duplicate is `DELETE`+`INSERT`.
- **External content** (`content='clip'`) → no duplicated text, `snippet()` works, `'rebuild'`
  recovers.
- **unicode61 only**, no trigram, no prefix index → 3 MB/10k clips instead of ~25 MB, and 1–2
  character prefixes already work at ~1 ms. Add trigram later *only* if users ask for infix.
- **No `auto_vacuum`** → measured no benefit at steady state; `VACUUM` only when the cap shrinks.
- `preview` is a separate, short, normalized column → the search index stays small and the list
  query never touches `body`.

```sql
-- ---------------------------------------------------------------- connection
PRAGMA journal_mode = WAL;
PRAGMA synchronous  = NORMAL;
PRAGMA busy_timeout = 5000;
PRAGMA foreign_keys = ON;

-- ---------------------------------------------------------------- core tables
CREATE TABLE clip (
  id        INTEGER PRIMARY KEY,     -- monotonic == recency; bump = new rowid
  preview   TEXT    NOT NULL,        -- normalized single line, <= 200 chars (indexed)
  body      TEXT,                    -- full text; NULL when spilled to a file
  ocr       TEXT,                    -- Vision output, first ~2k chars (indexed)
  kind      TEXT    NOT NULL,        -- 'text'|'rtf'|'html'|'image'|'files'
  app_id    TEXT,                    -- source bundle id
  created   INTEGER NOT NULL,        -- unix seconds; updated on bump
  pinned    INTEGER NOT NULL DEFAULT 0,
  byte_size INTEGER NOT NULL,
  hash      BLOB    NOT NULL,        -- SHA-256 of normalized content
  blob_id   INTEGER REFERENCES blob(id) ON DELETE CASCADE,
  body_path TEXT                     -- set when body spilled to disk (> ~1 MB)
);

CREATE UNIQUE INDEX clip_hash   ON clip(hash);                       -- dedupe probe
CREATE INDEX        clip_recent ON clip(pinned DESC, created DESC, id DESC);
CREATE INDEX        clip_app    ON clip(app_id, id DESC);

-- image bytes, deduped across clips by sha256
CREATE TABLE blob (
  id        INTEGER PRIMARY KEY,
  sha256    BLOB    NOT NULL UNIQUE,
  mime      TEXT    NOT NULL,
  bytes     BLOB    NOT NULL,
  byte_size INTEGER NOT NULL
);

-- thumbnails live in SQLite: ~8-16 KB, one pread, same row as the list query
CREATE TABLE thumb (
  clip_id INTEGER PRIMARY KEY REFERENCES clip(id) ON DELETE CASCADE,
  w       INTEGER NOT NULL,
  h       INTEGER NOT NULL,
  bytes   BLOB    NOT NULL
);

-- ---------------------------------------------------------------- full-text
-- External content: no text duplication, snippet()/highlight() work,
-- 'rebuild' recovers from any drift.
CREATE VIRTUAL TABLE clip_fts USING fts5(
  preview, ocr,
  content='clip', content_rowid='id',
  tokenize="unicode61 remove_diacritics 2"
);

-- Both columns of the FTS table MUST exist on the content table.
-- All three triggers MUST pass old.* values verbatim to 'delete', or the
-- index desynchronises and integrity-check reports
-- "database disk image is malformed".
CREATE TRIGGER clip_ai AFTER INSERT ON clip BEGIN
  INSERT INTO clip_fts(rowid, preview, ocr)
    VALUES (new.id, new.preview, new.ocr);
END;

CREATE TRIGGER clip_ad AFTER DELETE ON clip BEGIN
  INSERT INTO clip_fts(clip_fts, rowid, preview, ocr)
    VALUES ('delete', old.id, old.preview, old.ocr);
END;

CREATE TRIGGER clip_au AFTER UPDATE OF preview, ocr ON clip BEGIN
  INSERT INTO clip_fts(clip_fts, rowid, preview, ocr)
    VALUES ('delete', old.id, old.preview, old.ocr);
  INSERT INTO clip_fts(rowid, preview, ocr)
    VALUES (new.id, new.preview, new.ocr);
END;
```

**Hot query — search-as-you-type, newest first, all filters, 0.05 ms measured:**

```sql
SELECT c.id, c.preview, c.kind, c.app_id, c.created, c.pinned
  FROM clip_fts f
  JOIN clip c ON c.id = f.rowid
 WHERE f.clip_fts MATCH ?            -- escaped prefix query, see §1.8
   AND (?1 IS NULL OR c.app_id  = ?1)
   AND (?2 = 0    OR c.kind     = ?2)
   AND (?3 = 0    OR c.pinned   = 1)
   AND c.created >= ?4
 ORDER BY f.rowid DESC
 LIMIT 50;
```

**List query — empty search box, uses `clip_recent`:**

```sql
SELECT id, preview, kind, app_id, created, pinned
  FROM clip ORDER BY created DESC LIMIT 50;          -- 0.008 ms measured
-- subsequent pages: WHERE created < ?1 ORDER BY created DESC LIMIT 50
```

**Ongoing maintenance (background queue, after eviction batches / on idle):**

```sql
INSERT INTO clip_fts(clip_fts, rank) VALUES('merge', 8);   -- cheap, often
INSERT INTO clip_fts(clip_fts) VALUES('optimize');         -- full, idle only
-- repair, only if integrity-check reports drift:
INSERT INTO clip_fts(clip_fts) VALUES('rebuild');
-- only when the history cap is LOWERED:
VACUUM;
```

**Schema evolution note:** whenever you add a column to `clip_fts`, you must also add it to
`clip`, add it to all three triggers, and run `'rebuild'`. Put a migration test that runs
`integrity-check` with `rank=1` after every migration — that single assertion would have caught
every FTS5 bug reproduced in §1.2.

---

## 7. Explicitly unverified

Listed so nobody downstream quotes them as fact:

1. **Published FTS5 benchmarks at 100k–1M rows.** None found. I searched and found only the
   SQLite forum thread in §1.11 (real 1M-row contentless_delete index; 0.13 s → 0.24 s for one
   query) — a single anecdote, not a benchmark. All performance numbers in this brief are my own
   measurements on the corpus in §0.
2. **Vision OCR latency per image.** Unmeasurable here (Vision throws `nilError` in the sandbox).
   See §3.3; measure with a signpost before making any UI promise.
3. **Binary size / startup time of GRDB vs SwiftData vs Core Data vs raw C.** Not measured, no
   primary source found. §2.1 ranking is architectural reasoning only.
4. **Core Data with FTS5.** No maintained production example found. Treat "possible but
   advanced and unsupported" as unverified.
5. **Clipboard apps' published performance claims.** None found for any macOS clipboard manager.
   The targets in §5.3 are engineering budgets, not industry figures.
6. **`PRAGMA page_size = 8192`.** Often recommended for text-heavy DBs; not measured here. Worth
   one A/B on the real corpus before adopting.
7. **`ORDER BY rowid DESC` on FTS5 is not a documented ordering guarantee** (§1.7). Measured
   fast on 3.54.0. Guard it with a plan-and-latency regression test.
8. **The 1 MB spill-to-file threshold** (§1.10) is judgement, not measurement.
9. **Per-OS availability.** FTS5 + trigram verified on macOS 27.0.1 system `libsqlite3`
   (3.54.0). If you support older macOS, re-verify per version, or bundle SQLite to be safe.
10. **Image storage math (§3.1)** is arithmetic on assumed typical sizes, not a measured corpus.
