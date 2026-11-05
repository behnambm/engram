import CryptoKit
import Foundation
import SQLite3

struct Clip: Identifiable {
    let id: Int64
    let text: String
    let appName: String?
    let createdAt: Date

    /// One line for the list: newlines and runs of whitespace collapsed.
    var preview: String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

enum ClipStoreError: LocalizedError {
    case sqlite(String)

    var errorDescription: String? {
        switch self {
        case .sqlite(let message): message
        }
    }
}

/// Clipboard history in SQLite.
///
/// `id` comes from the rowid, so ascending `id` *is* the copy order: "newest first" is
/// `ORDER BY id DESC` with no timestamp sort and no index. That is what keeps lookups
/// in the sub-millisecond range as the history grows (see docs/clipboard-manager-research.md).
@MainActor
final class ClipStore {
    private var db: OpaquePointer?

    /// Tell SQLite to copy bound strings immediately; they are Swift temporaries.
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init() throws {
        let directory = URL.applicationSupportDirectory.appending(path: "Siaheh", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "history.sqlite")

        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            throw ClipStoreError.sqlite(lastError)
        }

        try execute("PRAGMA journal_mode = WAL")
        try execute("PRAGMA synchronous = NORMAL")
        try execute("""
            CREATE TABLE IF NOT EXISTS clips(
                id INTEGER PRIMARY KEY,
                created_at REAL NOT NULL,
                app_name TEXT,
                app_bundle TEXT,
                hash BLOB NOT NULL,
                text TEXT NOT NULL
            )
            """)
        try execute("CREATE UNIQUE INDEX IF NOT EXISTS clips_hash ON clips(hash)")
        try setUpFullTextSearch()
    }

    /// FTS5 over `clips.text`, kept in sync by triggers. Existing rows are indexed once,
    /// so adding search to an existing database does not lose history.
    ///
    /// The index is external-content (`content='clips'`): it stores only the index, and
    /// `rowid` stays equal to `clips.id`, which is what makes newest-first search cheap.
    private func setUpFullTextSearch() throws {
        let alreadyIndexed = try tableExists("clips_fts")

        try execute("""
            CREATE VIRTUAL TABLE IF NOT EXISTS clips_fts USING fts5(
                text, content='clips', content_rowid='id',
                tokenize='unicode61 remove_diacritics 2'
            )
            """)
        try execute("""
            CREATE TRIGGER IF NOT EXISTS clips_fts_insert AFTER INSERT ON clips BEGIN
                INSERT INTO clips_fts(rowid, text) VALUES (new.id, new.text);
            END
            """)
        try execute("""
            CREATE TRIGGER IF NOT EXISTS clips_fts_delete AFTER DELETE ON clips BEGIN
                INSERT INTO clips_fts(clips_fts, rowid, text) VALUES ('delete', old.id, old.text);
            END
            """)
        try execute("""
            CREATE TRIGGER IF NOT EXISTS clips_fts_update AFTER UPDATE ON clips BEGIN
                INSERT INTO clips_fts(clips_fts, rowid, text) VALUES ('delete', old.id, old.text);
                INSERT INTO clips_fts(rowid, text) VALUES (new.id, new.text);
            END
            """)

        if !alreadyIndexed {
            try execute("INSERT INTO clips_fts(clips_fts) VALUES ('rebuild')")
        }
    }

    private func tableExists(_ name: String) throws -> Bool {
        let statement = try prepare("SELECT 1 FROM sqlite_master WHERE name = ? LIMIT 1")
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, name, -1, Self.transient)
        return sqlite3_step(statement) == SQLITE_ROW
    }

    // MARK: - Writing

    /// Stores a clip. An identical clip (same hash) is removed first so the new row
    /// becomes the newest — "bump to top" instead of a duplicate row.
    func insert(text: String, appName: String?, appBundle: String?) throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let hash = Data(SHA256.hash(data: Data(text.utf8)))

        try transaction {
            let delete = try prepare("DELETE FROM clips WHERE hash = ?")
            _ = hash.withUnsafeBytes { bytes in
                sqlite3_bind_blob(delete, 1, bytes.baseAddress, Int32(bytes.count), Self.transient)
            }
            try step(delete)
            sqlite3_finalize(delete)

            let insert = try prepare("""
                INSERT INTO clips(created_at, app_name, app_bundle, hash, text)
                VALUES(?, ?, ?, ?, ?)
                """)
            sqlite3_bind_double(insert, 1, Date().timeIntervalSince1970)
            if let appName { sqlite3_bind_text(insert, 2, appName, -1, Self.transient) }
            if let appBundle { sqlite3_bind_text(insert, 3, appBundle, -1, Self.transient) }
            _ = hash.withUnsafeBytes { bytes in
                sqlite3_bind_blob(insert, 4, bytes.baseAddress, Int32(bytes.count), Self.transient)
            }
            sqlite3_bind_text(insert, 5, text, -1, Self.transient)
            try step(insert)
            sqlite3_finalize(insert)
        }
    }

    /// Drops the oldest clips beyond the configured limit. A limit of 0 keeps everything.
    func enforceRetention() {
        let limit = Settings.retentionLimit
        guard limit > 0 else { return }

        do {
            try transaction {
                let statement = try prepare("""
                    DELETE FROM clips WHERE id NOT IN (
                        SELECT id FROM clips ORDER BY id DESC LIMIT ?
                    )
                    """)
                sqlite3_bind_int(statement, 1, Int32(limit))
                try step(statement)
                sqlite3_finalize(statement)
            }
        } catch {
            // Trimming is housekeeping, not a user action: log it instead of interrupting.
            NSLog("Siaheh: could not trim clipboard history: \(error.localizedDescription)")
        }
    }

    func deleteAll() {
        try? execute("DELETE FROM clips")
    }

    // MARK: - Reading

    func recent(limit: Int) -> [Clip] {
        guard let statement = try? prepare("""
            SELECT id, text, app_name, created_at FROM clips ORDER BY id DESC LIMIT ?
            """) else { return [] }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, Int32(limit))
        return readClips(from: statement)
    }

    /// Searches the *whole* history, newest first.
    ///
    /// Word-prefix search (what typing produces) is served by FTS5. A mid-word query has no
    /// FTS tokens to match, so it falls back to a substring scan — correct rather than fast,
    /// and only paid when the fast path found nothing.
    func search(_ query: String, limit: Int) -> [Clip] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return recent(limit: limit) }

        let matches = fullTextSearch(trimmed, limit: limit)
        return matches.isEmpty ? substringSearch(trimmed, limit: limit) : matches
    }

    private func fullTextSearch(_ query: String, limit: Int) -> [Clip] {
        guard let expression = Self.matchExpression(for: query) else { return [] }
        // ORDER BY the FTS table's rowid, never the joined column and never `rank`:
        // rowid is the copy order, so this stops as soon as it has enough rows (0.03–2 ms
        // at 100k clips) instead of scoring every match (12–25 ms).
        guard let statement = try? prepare("""
            SELECT c.id, c.text, c.app_name, c.created_at
            FROM clips_fts f JOIN clips c ON c.id = f.rowid
            WHERE clips_fts MATCH ?
            ORDER BY f.rowid DESC
            LIMIT ?
            """) else { return [] }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, expression, -1, Self.transient)
        sqlite3_bind_int(statement, 2, Int32(limit))
        return readClips(from: statement)
    }

    private func substringSearch(_ query: String, limit: Int) -> [Clip] {
        let escaped = query
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")

        guard let statement = try? prepare("""
            SELECT id, text, app_name, created_at FROM clips
            WHERE text LIKE ? ESCAPE '\\'
            ORDER BY id DESC LIMIT ?
            """) else { return [] }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, "%\(escaped)%", -1, Self.transient)
        sqlite3_bind_int(statement, 2, Int32(limit))
        return readClips(from: statement)
    }

    /// Turns free text into an FTS5 expression that cannot be malformed.
    ///
    /// Tokens are split on anything non-alphanumeric and quoted, so `col:val`, `(`, `AND`
    /// and `"unclosed` are searched literally instead of raising an FTS syntax error. The
    /// trailing `*` sits outside the quotes — that is what makes it a prefix match.
    static func matchExpression(for input: String) -> String? {
        let tokens = input.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return nil }

        return tokens.enumerated().map { index, token in
            let escaped = token.replacingOccurrences(of: "\"", with: "\"\"")
            return index == tokens.count - 1 ? "\"\(escaped)\"*" : "\"\(escaped)\""
        }.joined(separator: " ")
    }

    var count: Int {
        guard let statement = try? prepare("SELECT COUNT(*) FROM clips") else { return 0 }
        defer { sqlite3_finalize(statement) }
        return sqlite3_step(statement) == SQLITE_ROW ? Int(sqlite3_column_int64(statement, 0)) : 0
    }

    private func readClips(from statement: OpaquePointer) -> [Clip] {
        var clips: [Clip] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let text = sqlite3_column_text(statement, 1) else { continue }
            clips.append(Clip(
                id: sqlite3_column_int64(statement, 0),
                text: String(cString: text),
                appName: sqlite3_column_text(statement, 2).map { String(cString: $0) },
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3))
            ))
        }
        return clips
    }

    // MARK: - SQLite plumbing

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw ClipStoreError.sqlite(lastError)
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw ClipStoreError.sqlite(lastError)
        }
        return statement
    }

    private func step(_ statement: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw ClipStoreError.sqlite(lastError)
        }
    }

    private func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            try body()
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private var lastError: String {
        db.map { String(cString: sqlite3_errmsg($0)) } ?? "database is not open"
    }
}
