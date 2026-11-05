#!/usr/bin/env python3
"""Reproduce the FTS5 numbers in docs/clipboard-manager-research.md (section 4).

Builds a 100k-clip SQLite database with a realistic clipboard size distribution,
then times the query shapes a clipboard manager actually issues, and asserts that
the "fast" shapes stay fast. Run: python3 benchmarks/fts5_bench.py [--rows N]

Requires the system SQLite (macOS 27 ships 3.54.0 with FTS5).
"""

import argparse
import os
import random
import sqlite3
import statistics
import sys
import time

WORDS = (
    "invoice client payment meeting timesheet github branch deploy review schedule lunch "
    "feedback reminder approve marketing campaign release hotfix spec design sprint retro "
    "budget contract payroll signature address password"
).split()
CODE = [
    "processPayment", "orderId", "async", "await", "fetch", "AppConfig", "prod", "staging",
    "npm install", "git checkout", "ssh-rsa", "sk-proj-abc123", "https://api.example.com/v2/users",
]
APPS = ["Xcode", "Safari", "Slack", "Terminal", "Mail", "Notes", "Figma", "Linear"]
KINDS = ["text", "text", "text", "url", "code", "email"]

# Budgets from the doc's target table (4.5). Anything faster than these is a pass.
FAST_MS = 5.0


def build(db_path, rows, seed=42):
    random.seed(seed)
    if os.path.exists(db_path):
        os.remove(db_path)
    con = sqlite3.connect(db_path)
    con.execute("PRAGMA journal_mode=WAL")
    con.execute("PRAGMA synchronous=NORMAL")
    con.executescript("""
    CREATE TABLE clips(
      id INTEGER PRIMARY KEY, ts INTEGER NOT NULL, app TEXT NOT NULL,
      kind TEXT NOT NULL, hash BLOB NOT NULL, text TEXT NOT NULL);
    CREATE VIRTUAL TABLE fts_uni USING fts5(
      text, content='clips', content_rowid='id', tokenize='unicode61 remove_diacritics 2');
    CREATE INDEX idx_ts ON clips(ts DESC);
    CREATE INDEX idx_app_ts ON clips(app, ts DESC);
    """)

    def make(i):
        r = random.random()
        if r < 0.70:
            n = random.randint(10, 120)
        elif r < 0.95:
            n = random.randint(200, 1500)
        else:
            n = random.randint(2000, 20000)
        pool = WORDS * 3 + CODE
        parts, total = [], 0
        while total < n:
            w = random.choice(pool)
            parts.append(w)
            total += len(w) + 1
            if random.random() < 0.05:
                parts.append(str(random.randint(1, 99999)))
        text = " ".join(parts)[:n]
        if KINDS[i % len(KINDS)] == "email":
            text = f"Re: {text[:60]}...\n\n{text}"
        return (1700000000 + i * 60, random.choice(APPS), KINDS[i % len(KINDS)], os.urandom(8), text)

    t0 = time.perf_counter()
    con.executemany("INSERT INTO clips(ts,app,kind,hash,text) VALUES(?,?,?,?,?)",
                    (make(i) for i in range(rows)))
    con.commit()
    insert_s = time.perf_counter() - t0

    t0 = time.perf_counter()
    con.execute("INSERT INTO fts_uni(fts_uni) VALUES('rebuild')")
    con.commit()
    index_s = time.perf_counter() - t0
    return con, insert_s, index_s


def ms(fn, n=150):
    samples = []
    for _ in range(n):
        t0 = time.perf_counter()
        rows = fn()
        samples.append((time.perf_counter() - t0) * 1000)
    samples.sort()
    return statistics.median(samples), samples[int(len(samples) * 0.95)], len(rows)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--rows", type=int, default=100_000)
    ap.add_argument("--db", default="/tmp/clips_bench.db")
    args = ap.parse_args()

    con, insert_s, index_s = build(args.db, args.rows)
    print(f"corpus: {args.rows:,} clips")
    print(f"  insert  : {insert_s:6.2f}s")
    print(f"  FTS build: {index_s:6.2f}s")

    raw = con.execute("SELECT SUM(length(text)) FROM clips").fetchone()[0]
    content = con.execute(
        "SELECT SUM(pgsize) FROM dbstat WHERE name IN ('clips','idx_ts','idx_app_ts')").fetchone()[0]
    fts = con.execute("SELECT SUM(pgsize) FROM dbstat WHERE name LIKE 'fts_uni%'").fetchone()[0]
    per10k = lambda b: b / (args.rows / 10_000) / 1e6  # noqa: E731
    print(f"  raw text: {raw/1e6:.1f} MB | content: {content/1e6:.1f} MB "
          f"({per10k(content):.1f} MB/10k) | FTS: {fts/1e6:.1f} MB ({per10k(fts):.1f} MB/10k)")

    print("\n-- query latency (p50 / p95, LIMIT 50-100) --")
    cases = [
        ("fast", "MATCH newest-first",
         lambda: con.execute("SELECT rowid FROM fts_uni WHERE fts_uni MATCH ? "
                             "ORDER BY rowid DESC LIMIT 50", ("invoice",)).fetchall()),
        ("fast", "MATCH prefix newest-first",
         lambda: con.execute("SELECT rowid FROM fts_uni WHERE fts_uni MATCH ? "
                             "ORDER BY rowid DESC LIMIT 50", ("invo*",)).fetchall()),
        ("fast", "MATCH join, ORDER BY f.rowid DESC",
         lambda: con.execute("SELECT c.id,c.app FROM fts_uni f JOIN clips c ON c.id=f.rowid "
                             "WHERE fts_uni MATCH ? ORDER BY f.rowid DESC LIMIT 50",
                             ("invoice",)).fetchall()),
        ("fast", "filter-only browse",
         lambda: con.execute("SELECT id,text FROM clips WHERE app=? ORDER BY id DESC LIMIT 50",
                             ("Xcode",)).fetchall()),
        ("slow", "MATCH join, ORDER BY c.id DESC (temp b-tree)",
         lambda: con.execute("SELECT c.id,c.app FROM fts_uni f JOIN clips c ON c.id=f.rowid "
                             "WHERE fts_uni MATCH ? ORDER BY c.id DESC LIMIT 50",
                             ("invoice",)).fetchall()),
        ("slow", "MATCH ORDER BY rank",
         lambda: con.execute("SELECT rowid FROM fts_uni WHERE fts_uni MATCH ? "
                             "ORDER BY rank LIMIT 50", ("invoice",)).fetchall()),
        ("slow", "naive LIKE full scan",
         lambda: con.execute("SELECT COUNT(*) FROM clips WHERE text LIKE ?",
                             ("%zzqqxx%",)).fetchall()),
    ]
    failures = []
    for expected, label, fn in cases:
        p50, p95, n = ms(fn)
        verdict = "ok " if (expected == "fast") == (p50 < FAST_MS) else "FAIL"
        if verdict == "FAIL":
            failures.append(label)
        print(f"  [{verdict}] {label:<48} p50={p50:8.3f}ms p95={p95:8.3f}ms rows={n}")

    plan = " ".join(r[3] for r in con.execute(
        "EXPLAIN QUERY PLAN SELECT c.id FROM fts_uni f JOIN clips c ON c.id=f.rowid "
        "WHERE fts_uni MATCH ? ORDER BY f.rowid DESC LIMIT 50", ("invoice",)))
    print(f"\nquery plan (must not sort): {plan}")
    if "TEMP B-TREE" in plan.upper():
        failures.append("query plan regression: TEMP B-TREE FOR ORDER BY")

    con.close()
    if failures:
        print("\nFAILED: " + "; ".join(failures))
        return 1
    print("\nall budgets held")
    return 0


if __name__ == "__main__":
    sys.exit(main())
