import Foundation

var failures = 0
func check(_ name: String, _ cond: Bool) {
    if cond { print("PASS  \(name)") }
    else { failures += 1; print("FAIL  \(name)") }
}

// NOTE: this suite runs under `run.sh`, which isolates UserDefaults + Application
// Support into a temp HOME via CFFIXED_USER_HOME. `deleteAll()` here only ever touches
// that throwaway DB — never the real ~/Library/Application Support/Engram/history.sqlite.
@main
struct Tests {
    @MainActor
    static func main() throws {
        let store = try ClipStore()

        // MARK: insert() — empty / whitespace-only text is ignored
        let baseCount = store.count
        try store.insert(text: "", appName: "AppA", appBundle: nil)
        try store.insert(text: "   ", appName: "AppA", appBundle: nil)
        try store.insert(text: "\n\t\r\n", appName: "AppA", appBundle: nil)
        try store.insert(text: "\u{00A0}\u{00A0}\u{2007}", appName: "AppA", appBundle: nil) // NBSP + figure space
        check("insert ignores empty text", store.count == baseCount)
        check("insert ignores whitespace-only text (spaces/tabs/newlines)", store.count == baseCount)
        check("insert ignores Unicode-space-only text (NBSP/figure-space)", store.count == baseCount)
        try store.insert(text: "  hello  ", appName: "AppA", appBundle: nil)
        check("insert keeps whitespace-wrapped text", store.recent(limit: 1).first?.text == "  hello  ")

        // MARK: insert() — newest-first ordering + exact dedup
        store.deleteAll()
        try store.insert(text: "alpha", appName: "AppA", appBundle: nil)
        try store.insert(text: "beta gamma", appName: "AppB", appBundle: nil)
        try store.insert(text: "delta", appName: "AppC", appBundle: nil)
        check("recent is newest-first",
              store.recent(limit: 10).map(\.text) == ["delta", "beta gamma", "alpha"])

        // same text, same app -> bump to top, still one row
        try store.insert(text: "alpha", appName: "AppA", appBundle: nil)
        let afterBump = store.recent(limit: 10)
        check("duplicate bumps to top without dup",
              afterBump.map(\.text) == ["alpha", "delta", "beta gamma"] && afterBump.count == 3)

        // same text, different app -> still one row, appName updated, bumped to top
        try store.insert(text: "alpha", appName: "AppZ", appBundle: nil)
        let afterDiffApp = store.recent(limit: 10)
        check("same text different app stays one row", store.count == 3)
        check("same text different app bumps to top", afterDiffApp.first?.text == "alpha")
        check("same text different app updates appName", afterDiffApp.first?.appName == "AppZ")

        // dedup is exact-byte: a leading/trailing space makes a *different* clip
        store.deleteAll()
        try store.insert(text: "hello", appName: "AppA", appBundle: nil)
        try store.insert(text: " hello", appName: "AppA", appBundle: nil)
        try store.insert(text: "hello ", appName: "AppA", appBundle: nil)
        check("whitespace difference => distinct rows (dedup is exact-byte)", store.count == 3)

        // MARK: preview() — whitespace collapse + exact 240-char boundary
        store.deleteAll()
        try store.insert(text: "line1\nline2   line3", appName: "X", appBundle: nil)
        check("preview collapses newlines + runs of spaces",
              store.recent(limit: 1).first?.preview == "line1 line2 line3")
        try store.insert(text: "  leading and trailing  \n", appName: "X", appBundle: nil)
        check("preview trims leading/trailing whitespace",
              store.recent(limit: 1).first?.preview == "leading and trailing")
        try store.insert(text: "a\t\tb", appName: "X", appBundle: nil)
        check("preview collapses tabs", store.recent(limit: 1).first?.preview == "a b")
        try store.insert(text: "x\ny", appName: "X", appBundle: nil)
        check("preview collapses but full text preserved",
              store.recent(limit: 1).first.map { $0.preview == "x y" && $0.text == "x\ny" } == true)

        let exact240 = String(repeating: "a", count: 120) + "\n" + String(repeating: "b", count: 119) // collapses to 240 chars
        try store.insert(text: exact240, appName: "X", appBundle: nil)
        check("preview exact 240 chars is NOT truncated",
              store.recent(limit: 1).first?.preview.count == 240)
        let over240 = String(repeating: "a", count: 120) + "\n" + String(repeating: "b", count: 120) // collapses to 241 chars
        try store.insert(text: over240, appName: "X", appBundle: nil)
        check("preview 241 chars is capped to 240",
              store.recent(limit: 1).first?.preview.count == 240)

        // MARK: search() — prefix, substring fallback, case
        store.deleteAll()
        try store.insert(text: "alpha", appName: "AppA", appBundle: nil)
        try store.insert(text: "beta gamma", appName: "AppB", appBundle: nil)
        try store.insert(text: "delta", appName: "AppC", appBundle: nil)
        check("empty query == recent", store.search("", limit: 10).map(\.text) == ["delta", "beta gamma", "alpha"])
        check("whitespace query == recent", store.search("   ", limit: 10).count == 3)
        check("prefix match 'alp'", store.search("alp", limit: 10).map(\.text) == ["alpha"])
        check("substring fallback 'pha'", store.search("pha", limit: 10).map(\.text) == ["alpha"])
        check("case-insensitive 'ALPHA'", store.search("ALPHA", limit: 10).map(\.text) == ["alpha"])

        // Documented trade-off (see docs/ux-review/functional.md BUG-1): when FTS finds
        // ANY prefix hit, the substring fallback is skipped, so a query that is both a
        // prefix of one clip and a mid-word substring of another returns only the prefix
        // hits. "alpha" contains "pha" mid-word but is not returned once "pharmacy"
        // exists. This is deliberate (unioning would force a full-table LIKE scan on
        // every search); the lead benchmarked it and documented the decision in
        // ClipStore.search().
        try store.insert(text: "pharmacy", appName: "AppD", appBundle: nil)
        check("documented trade-off: prefix hit suppresses mid-word substring hit",
              store.search("pha", limit: 10).map(\.text) == ["pharmacy"])

        // MARK: search() — multi-token: full words AND, last token is the prefix
        store.deleteAll()
        try store.insert(text: "alpha delta omega", appName: "X", appBundle: nil)
        try store.insert(text: "beta gamma", appName: "X", appBundle: nil)
        check("multi-token: all full words match",
              store.search("alpha delta", limit: 10).map(\.text).contains("alpha delta omega"))
        check("multi-token: last token prefix matches",
              store.search("alpha del", limit: 10).map(\.text).contains("alpha delta omega"))
        check("multi-token: earlier token is NOT a prefix (by design)",
              !store.search("alp del", limit: 10).map(\.text).contains("alpha delta omega"))

        // MARK: search() — FTS-hostile input searched literally, never crashes
        store.deleteAll()
        try store.insert(text: "foo OR bar AND baz NEAR qux NOT here", appName: "X", appBundle: nil)
        for word in ["OR", "AND", "NEAR", "NOT"] {
            check("operator word \(word) searched literally (no crash)",
                  store.search(word, limit: 10).map(\.text).contains("foo OR bar AND baz NEAR qux NOT here"))
        }
        store.deleteAll()
        try store.insert(text: "a (b) c:d %_ \"x\" 'y'", appName: "X", appBundle: nil)
        check("parenthesis '(' searched literally", store.search("(", limit: 10).map(\.text).contains("a (b) c:d %_ \"x\" 'y'"))
        check("parenthesis ')' searched literally", store.search(")", limit: 10).map(\.text).contains("a (b) c:d %_ \"x\" 'y'"))
        check("colon ':' searched literally", store.search(":", limit: 10).map(\.text).contains("a (b) c:d %_ \"x\" 'y'"))
        check("percent '%' searched literally", store.search("%", limit: 10).map(\.text).contains("a (b) c:d %_ \"x\" 'y'"))
        check("underscore '_' searched literally", store.search("_", limit: 10).map(\.text).contains("a (b) c:d %_ \"x\" 'y'"))
        check("double-quote searched literally", store.search("\"", limit: 10).map(\.text).contains("a (b) c:d %_ \"x\" 'y'"))
        check("single-quote searched literally", store.search("'", limit: 10).map(\.text).contains("a (b) c:d %_ \"x\" 'y'"))
        check("mixed hostile 'col:val AND (unclosed' does not crash",
              store.search("col:val AND \"unclosed (paren", limit: 10).count >= 0)
        check("hostile '%_' does not crash", store.search("%_", limit: 10).count >= 0)
        check("hostile 'NEAR/3' does not crash", store.search("NEAR/3", limit: 10).count >= 0)

        // MARK: search() — Persian, Arabic, mixed-script
        store.deleteAll()
        try store.insert(text: "تقریبا سه هفته", appName: "Chrome", appBundle: nil)
        check("Persian prefix search", store.search("تقری", limit: 10).map(\.text).contains("تقریبا سه هفته"))
        check("Persian mid-word substring search", store.search("قری", limit: 10).map(\.text).contains("تقریبا سه هفته"))
        check("Persian full-word search", store.search("هفته", limit: 10).map(\.text).contains("تقریبا سه هفته"))
        try store.insert(text: "السلام عليكم", appName: "Chrome", appBundle: nil)
        check("Arabic full-word search", store.search("السلام", limit: 10).map(\.text).contains("السلام عليكم"))
        check("Arabic mid-word substring search", store.search("سلام", limit: 10).map(\.text).contains("السلام عليكم"))
        try store.insert(text: "hello سلام world 123", appName: "X", appBundle: nil)
        check("mixed-script: Arabic token", store.search("سلام", limit: 10).map(\.text).contains("hello سلام world 123"))
        check("mixed-script: Latin token", store.search("world", limit: 10).map(\.text).contains("hello سلام world 123"))
        check("mixed-script: digit token", store.search("123", limit: 10).map(\.text).contains("hello سلام world 123"))

        // MARK: enforceRetention()
        store.deleteAll()
        Settings.retentionLimit = 5
        try store.insert(text: "c1", appName: "X", appBundle: nil)
        try store.insert(text: "c2", appName: "X", appBundle: nil)
        store.enforceRetention()
        check("retention limit > count is a no-op", store.count == 2)
        Settings.retentionLimit = 2
        store.enforceRetention()
        check("retention limit == count is a no-op", store.count == 2)
        Settings.retentionLimit = 1
        store.enforceRetention()
        check("retention limit 1 keeps exactly the newest", store.count == 1 && store.recent(limit: 1).first?.text == "c2")

        store.deleteAll()
        Settings.retentionLimit = 3
        for t in ["c1", "c2", "c3", "c4", "c5"] { try store.insert(text: t, appName: "X", appBundle: nil) }
        store.enforceRetention()
        check("retention keeps exactly the N newest", store.count == 3 && store.recent(limit: 3).map(\.text) == ["c5", "c4", "c3"])
        Settings.retentionLimit = 0
        store.enforceRetention()
        check("retention 0 keeps everything", store.count == 3)

        // MARK: count + recent() limit boundaries
        store.deleteAll()
        check("count is 0 on a fresh store", store.count == 0)
        for t in ["1", "2", "3", "4", "5"] { try store.insert(text: t, appName: "X", appBundle: nil) }
        check("count reflects inserted rows", store.count == 5)
        check("recent(limit: 0) is empty", store.recent(limit: 0).isEmpty)
        check("recent(limit: 1) returns the newest", store.recent(limit: 1).map(\.text) == ["5"])
        check("recent(limit: count) returns all", store.recent(limit: 5).count == 5)
        check("recent(limit: > count) returns all", store.recent(limit: 100).count == 5)
        check("recent(negative limit) returns all (SQLite LIMIT -1)", store.recent(limit: -1).count == 5)

        // MARK: HotKeyCombo.displayString — Apple order ⌃⌥⇧⌘ then key; bare key rejected
        check("bare key rejected (nil)", HotKeyCombo(keyCode: 9, modifierFlags: [], keyLabel: "v") == nil)
        let all = HotKeyCombo(keyCode: 9, modifierFlags: [.control, .option, .shift, .command], keyLabel: "v")
        check("all modifiers => ⌃⌥⇧⌘V", all?.displayString == "⌃⌥⇧⌘V")
        let ctrlCmd = HotKeyCombo(keyCode: 9, modifierFlags: [.control, .command], keyLabel: "v")
        check("control+command => ⌃⌘V", ctrlCmd?.displayString == "⌃⌘V")
        let shiftCmd = HotKeyCombo(keyCode: 9, modifierFlags: [.shift, .command], keyLabel: "v")
        check("shift+command => ⇧⌘V", shiftCmd?.displayString == "⇧⌘V")
        let optCmd = HotKeyCombo(keyCode: 9, modifierFlags: [.option, .command], keyLabel: "v")
        check("option+command => ⌥⌘V", optCmd?.displayString == "⌥⌘V")
        let optOnly = HotKeyCombo(keyCode: 9, modifierFlags: [.option], keyLabel: "v")
        check("option alone => ⌥V", optOnly?.displayString == "⌥V")
        let ctrlOnly = HotKeyCombo(keyCode: 9, modifierFlags: [.control], keyLabel: "v")
        check("control alone => ⌃V", ctrlOnly?.displayString == "⌃V")
        check("lowercase keyLabel is uppercased", optCmd?.displayString == "⌥⌘V")
        // The raw memberwise init does NOT reject a bare key (only the recording init does).
        check("raw init permits a bare key (surprising)", HotKeyCombo(keyCode: 9, modifiers: 0, keyLabel: "v").displayString == "V")

        // MARK: matchExpression()
        check("matchExpression single token", ClipStore.matchExpression(for: "foo") == "\"foo\"*")
        check("matchExpression lowercases", ClipStore.matchExpression(for: "Foo") == "\"foo\"*")
        check("matchExpression multi token", ClipStore.matchExpression(for: "foo bar") == "\"foo\" \"bar\"*")
        check("matchExpression appends * only to last token", ClipStore.matchExpression(for: "foo bar baz") == "\"foo\" \"bar\" \"baz\"*")
        check("matchExpression strips punctuation", ClipStore.matchExpression(for: "foo, bar!") == "\"foo\" \"bar\"*")
        check("matchExpression strips colon", ClipStore.matchExpression(for: "col:val") == "\"col\" \"val\"*")
        check("matchExpression strips parens", ClipStore.matchExpression(for: "(foo)") == "\"foo\"*")
        check("matchExpression strips dots", ClipStore.matchExpression(for: "a.b") == "\"a\" \"b\"*")
        check("matchExpression strips embedded quote", ClipStore.matchExpression(for: "foo\"bar") == "\"foo\" \"bar\"*")
        check("matchExpression empty returns nil", ClipStore.matchExpression(for: "") == nil)
        check("matchExpression whitespace returns nil", ClipStore.matchExpression(for: "   ") == nil)
        check("matchExpression punctuation-only returns nil", ClipStore.matchExpression(for: "!!!") == nil)

        print("")
        print(failures == 0 ? "ALL TESTS PASSED" : "\(failures) TEST(S) FAILED")
        exit(failures == 0 ? 0 : 1)
    }
}
