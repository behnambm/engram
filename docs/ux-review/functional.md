# Functional QA — Engram data layer (ClipStore · Settings · HotKeyCombo)

Scope: non-visual logic only. Harness: `scripts/ux-qa/run.sh` (compiles `ClipStore.swift`
+ `Settings.swift` + `Tests.swift`, runs under `CFFIXED_USER_HOME` isolation — the real DB
at `~/Library/Application Support/Engram/history.sqlite` is never opened, and no `DELETE`
ever touches it). `deleteAll()` is used inside the harness only against the throwaway DB.

Result: **77 tests, 77 PASS, 0 FAIL** (exit code 0).

---

## Test matrix

### insert()
| # | Case | Expected | Result |
|---|------|----------|--------|
| 1 | empty text `""` | ignored, no row | PASS |
| 2 | `"   "`, `"\n\t\r\n"` | ignored | PASS |
| 3 | NBSP + figure-space only (`\u{00A0}\u{2007}`) | ignored | PASS |
| 4 | `"  hello  "` (whitespace-wrapped, has content) | stored verbatim | PASS |
| 5 | newest-first ordering | `id DESC` | PASS |
| 6 | same text, same app | bump to top, still 1 row | PASS |
| 7 | same text, different app | still 1 row, `appName` updated, bumped | PASS |
| 8 | `hello` vs ` hello` vs `hello ` | 3 distinct rows (dedup is exact-byte) | PASS |

### preview()
| # | Case | Expected | Result |
|---|------|----------|--------|
| 9 | newlines + runs of spaces | collapsed to single spaces | PASS |
| 10 | leading/trailing whitespace | trimmed | PASS |
| 11 | tabs | collapsed | PASS |
| 12 | full text preserved after collapse | `.text` unchanged, `.preview` collapsed | PASS |
| 13 | exactly 240 chars (after collapse) | not truncated | PASS |
| 14 | 241 chars | capped to 240 | PASS |

### search()
| # | Case | Expected | Result |
|---|------|----------|--------|
| 15 | empty / whitespace query | returns `recent` | PASS |
| 16 | word-prefix `alp` → `alpha` | FTS prefix | PASS |
| 17 | mid-word `pha` → `alpha` (no prefix hit present) | substring fallback | PASS |
| 18 | case-insensitive `ALPHA` | match | PASS |
| 19 | **mid-word match when a prefix hit also exists** | see **BUG-1** | PASS (pins the bug) |
| 20 | multi-token all-full-words `alpha delta` | match | PASS |
| 21 | multi-token last-token-prefix `alpha del` | match | PASS |
| 22 | multi-token earlier-token-prefix `alp del` | no match (by design) | PASS |
| 23–26 | `OR` `AND` `NEAR` `NOT` | searched literally, no crash | PASS |
| 27–33 | `(` `)` `:` `%` `_` `"` `'` | searched literally, no crash | PASS |
| 34–36 | `col:val AND "unclosed (paren`, `%_`, `NEAR/3` | no crash | PASS |
| 37–39 | Persian prefix / mid-word / full-word | match | PASS |
| 40–41 | Arabic full-word / mid-word | match | PASS |
| 42–44 | mixed-script Arabic / Latin / digit token | match | PASS |

### enforceRetention()
| # | Case | Expected | Result |
|---|------|----------|--------|
| 45 | limit > count | no-op | PASS |
| 46 | limit == count | no-op | PASS |
| 47 | limit 1 | exactly the newest survives | PASS |
| 48 | limit 3 over 5 clips | exactly 3 newest survive | PASS |
| 49 | limit 0 | keeps everything | PASS |

### count / recent() boundaries
| # | Case | Expected | Result |
|---|------|----------|--------|
| 50 | fresh store | `count == 0` | PASS |
| 51 | after 5 inserts | `count == 5` | PASS |
| 52 | `recent(limit: 0)` | empty | PASS |
| 53 | `recent(limit: 1)` | newest only | PASS |
| 54 | `recent(limit: count)` | all | PASS |
| 55 | `recent(limit: > count)` | all | PASS |
| 56 | `recent(limit: -1)` | all (see **S-1**) | PASS |

### HotKeyCombo.displayString
| # | Case | Expected | Result |
|---|------|----------|--------|
| 57 | bare key (no modifier, recording init) | `nil` | PASS |
| 58 | ⌃⌥⇧⌘ | `⌃⌥⇧⌘V` | PASS |
| 59 | ⌃⌘ | `⌃⌘V` | PASS |
| 60 | ⇧⌘ | `⇧⌘V` | PASS |
| 61 | ⌥⌘ | `⌥⌘V` | PASS |
| 62 | ⌥ alone | `⌥V` | PASS |
| 63 | ⌃ alone | `⌃V` | PASS |
| 64 | lowercase keyLabel | uppercased | PASS |
| 65 | raw init with 0 modifiers | `"V"` (see **S-4**) | PASS |

### matchExpression()
| # | Case | Expected | Result |
|---|------|----------|--------|
| 66 | single token | `"foo"*` | PASS |
| 67 | lowercases | `"foo"*` | PASS |
| 68 | multi token | `"foo" "bar"*` | PASS |
| 69 | `*` only on last token | `"foo" "bar" "baz"*` | PASS |
| 70–73 | strips `,` `!` `:` `( )` `.` | tokens only | PASS |
| 74 | embedded `"` | stripped as separator | PASS |
| 75–77 | `""`, `"   "`, `"!!!"` | `nil` | PASS |

---

## Bugs found

### BUG-1 — mid-word matches are silently dropped when any FTS prefix hit exists
- **Severity:** Medium (search correctness; silent under-reporting of results).
- **Where:** `ClipStore.search()` (Sources/Engram/ClipStore.swift:184-190).
- **What happens:** `search` runs FTS first; only when FTS returns *zero* rows does it
  fall back to the `LIKE` substring scan. So a query that is *both* a prefix of one clip
  and a mid-word substring of another returns only the prefix hit.

  ```swift
  let matches = fullTextSearch(trimmed, limit: limit)
  return matches.isEmpty ? substringSearch(trimmed, limit: limit) : matches
  ```

- **Repro (harness, isolated):**
  1. `insert("alpha")` then `insert("pharmacy")`.
  2. `search("pha")` → returns `["pharmacy"]` only.
  3. Expected: `["pharmacy", "alpha"]` (both contain `pha`; `alpha` matches mid-word).
  4. Observed: `"alpha"` is missing. (Probe confirmed; also confirmed that with no
     `pharmacy` present, `search("pha")` correctly finds `alpha` via the fallback.)
- **Exact fix (do NOT apply in this task — lead owns Sources/):** union the two result
  sets, dedup by `id`, and keep newest-first order, instead of choosing one path:

  ```swift
  let fts = fullTextSearch(trimmed, limit: limit)
  let subs = substringSearch(trimmed, limit: limit)
  var seen = Set<Int64>(); var merged: [Clip] = []
  for clip in (fts + subs).sorted(by: { $0.id > $1.id })
      where seen.insert(clip.id).inserted {
      merged.append(clip); if merged.count == limit { break }
  }
  return merged
  ```

  Trade-off to weigh: this always runs the `LIKE` scan, losing the "only pay substring
  when FTS is empty" optimization. A cheaper variant is to run substring only when
  `fts.count < limit` (top-up the page), which fixes the visible case while keeping the
  fast path for saturated results.

---

## Surprising behavior (not necessarily bugs)

- **S-1 — `recent(limit: -1)` returns every row.** `LIMIT ?` binds `Int32(limit)`;
  SQLite treats a negative LIMIT as "no limit". Unreachable in the app (`HistoryWindow`
  always passes the fixed `displayLimit = 200`), but the public API silently returns the
  whole history for any negative limit.
- **S-2 — dedup is exact-byte, not normalized.** `"hello"`, `" hello"`, and `"hello "`
  are three separate rows (hash is over raw UTF-8). Combined with `preview` collapsing
  leading/trailing whitespace, three rows can show an identical preview.
- **S-3 — diacritic-carrying queries always take the slow substring path (and can miss
  NFD text).** FTS indexes with `remove_diacritics 2` (so `café` → `cafe` in the index),
  but `matchExpression` does not strip diacritics from the query, so a query like `café`
  never matches the index and falls back to `LIKE`. `LIKE` is byte-exact, so an NFD
  `café` (`cafe` + U+0301) is missed entirely by a `café` (NFC) query. Correctness is
  preserved for NFC text via the fallback; it is just slower and normalization-sensitive.
- **S-4 — the raw `HotKeyCombo(keyCode:modifiers:keyLabel:)` init permits a bare key.**
  Only the recording init (`modifierFlags:`) rejects no-modifier combos. A bare key can
  be reconstructed if `UserDefaults` is hand-edited (e.g. `modifiers == 0`), and its
  `displayString` is just the key with no modifier glyphs.
- **S-5 — multi-token search only prefix-matches the last token.** `alpha del` matches
  `alpha delta omega`, but `alp del` does not (earlier tokens must be full words). This is
  the documented design (`*` appended only to the last token), but typing a prefix for a
  non-final word returns nothing.

---

## How to re-run

```bash
scripts/ux-qa/run.sh   # 77 tests, exits 0
```

---

## Lead decision on BUG-1 (2026-11-09)

Not fixed — kept as a **documented trade-off**, not a silent bug. The lead benchmarked
the substring scan cost at 100k clips × ~200-char text: `LIKE '%q%'` = **12–16 ms** (and
worse with large clips), vs sub-millisecond FTS. Unioning prefix + substring results on
every search would add that full-table scan to the common prefix-search path and break the
app's headline "sub-millisecond at 100k clips" guarantee.

The trade-off is now explicit in `ClipStore.search()`'s doc comment, and the pinned test
was relabeled from "KNOWN BUG" to "documented trade-off". If correctness-over-speed is
ever preferred, the union fix (in the report above) is ready to apply; re-benchmark first.
