import Foundation
import SQLite3

/// The full-text index behind transcript search: one SQLite database (FTS5, the system library) with every
/// session's searchable messages. Lives in `~/Library/Application Support/Ensemble/search-index.sqlite`, or in
/// memory for tests and the preview engine. It is a cache: deleting the file only means indexing again.
public actor TranscriptSearchIndex {
    /// What the index holds for a session, to tell whether it is current.
    public struct Stamp: Hashable, Sendable {
        /// The session's `updated` date when it was indexed.
        public var updated: Date
        public var entryCount: Int
    }

    public enum IndexError: Error, LocalizedError {
        case open(String)
        case statement(String)

        public var errorDescription: String? {
            switch self {
            case .open(let message): "Could not open the search index: \(message)"
            case .statement(let message): "Search index error: \(message)"
            }
        }
    }

    /// Bump when the schema or the extracted text changes; an older file is emptied and filled again.
    static let schemaVersion: Int32 = 1

    /// Owns the SQLite handle and closes it with the index. Only the actor uses it.
    private final class Connection: @unchecked Sendable {
        let handle: OpaquePointer
        init(_ handle: OpaquePointer) { self.handle = handle }
        deinit { sqlite3_close(handle) }
    }

    private let connection: Connection
    private var db: OpaquePointer? { connection.handle }

    /// `fileURL` nil keeps the index in memory.
    public init(fileURL: URL?) throws {
        var handle: OpaquePointer?
        let path: String
        if let fileURL {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            path = fileURL.path
        } else {
            path = ":memory:"
        }
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            sqlite3_close(handle)
            throw IndexError.open(message)
        }
        connection = Connection(handle)
        try Self.prepareSchema(handle)
    }

    /// `~/Library/Application Support/Ensemble/search-index.sqlite`.
    public static var defaultFileURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("Ensemble", isDirectory: true).appendingPathComponent("search-index.sqlite")
    }

    // MARK: Schema

    private static func prepareSchema(_ db: OpaquePointer) throws {
        try exec(db, "PRAGMA journal_mode = WAL")
        try exec(db, "PRAGMA synchronous = NORMAL")
        var version: Int32 = 0
        try query(db, "PRAGMA user_version") { statement in version = sqlite3_column_int(statement, 0) }
        if version != schemaVersion {
            try exec(db, "DROP TABLE IF EXISTS messages_fts")
            try exec(db, "DROP TABLE IF EXISTS messages")
            try exec(db, "DROP TABLE IF EXISTS sessions")
        }
        try exec(db, """
        CREATE TABLE IF NOT EXISTS sessions (
            id TEXT PRIMARY KEY,
            updated REAL NOT NULL,
            entry_count INTEGER NOT NULL
        )
        """)
        try exec(db, """
        CREATE TABLE IF NOT EXISTS messages (
            rowid INTEGER PRIMARY KEY,
            session_id TEXT NOT NULL,
            item_id TEXT NOT NULL,
            role TEXT NOT NULL,
            ordinal INTEGER NOT NULL,
            text TEXT NOT NULL
        )
        """)
        try exec(db, "CREATE INDEX IF NOT EXISTS messages_session ON messages(session_id)")
        try exec(db, """
        CREATE VIRTUAL TABLE IF NOT EXISTS messages_fts USING fts5(
            text, content = 'messages', content_rowid = 'rowid', tokenize = 'unicode61 remove_diacritics 2'
        )
        """)
        try exec(db, "PRAGMA user_version = \(schemaVersion)")
    }

    // MARK: Reading

    /// What is indexed, by session id.
    public func stamps() throws -> [String: Stamp] {
        guard let db else { return [:] }
        var stamps: [String: Stamp] = [:]
        try Self.query(db, "SELECT id, updated, entry_count FROM sessions") { statement in
            let id = Self.text(statement, 0)
            stamps[id] = Stamp(updated: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
                               entryCount: Int(sqlite3_column_int64(statement, 2)))
        }
        return stamps
    }

    /// Messages holding every term of `query` (each as a word prefix), best SQLite rank first.
    public func hits(for query: TranscriptSearchQuery, limit: Int = 600) throws -> [TranscriptSearchRawHit] {
        guard let db, !query.isEmpty else { return [] }
        var hits: [TranscriptSearchRawHit] = []
        let sql = """
        SELECT m.session_id, m.item_id, m.role, m.ordinal, m.text, bm25(messages_fts)
        FROM messages_fts JOIN messages m ON m.rowid = messages_fts.rowid
        WHERE messages_fts MATCH ?1
        ORDER BY bm25(messages_fts)
        LIMIT ?2
        """
        try Self.query(db, sql, bind: { statement in
            Self.bind(statement, 1, query.ftsExpression)
            sqlite3_bind_int64(statement, 2, Int64(limit))
        }) { statement in
            hits.append(TranscriptSearchRawHit(
                sessionID: Self.text(statement, 0), itemID: Self.text(statement, 1),
                role: TranscriptSearchEntry.Role(rawValue: Self.text(statement, 2)) ?? .agent,
                ordinal: Int(sqlite3_column_int64(statement, 3)), text: Self.text(statement, 4),
                rank: sqlite3_column_double(statement, 5)))
        }
        return hits
    }

    /// Runs a search and ranks it in one step, off the main thread.
    public func search(_ query: TranscriptSearchQuery, sessions: [TranscriptSearchSession], filter: TranscriptSearchFilter,
                       folder: String?, now: Date = Date()) -> [TranscriptSearchResult] {
        let hits = (try? hits(for: query)) ?? []
        return TranscriptSearchRanker.rank(query: query, hits: hits, sessions: sessions, filter: filter, folder: folder, now: now)
    }

    // MARK: Writing

    /// Replaces everything indexed for a session with the searchable messages of `items`.
    @discardableResult
    public func replace(sessionID: String, updated: Date, items: [TranscriptItem]) throws -> Int {
        let entries = TranscriptSearchText.entries(items)
        try replace(sessionID: sessionID, updated: updated, entries: entries)
        return entries.count
    }

    public func replace(sessionID: String, updated: Date, entries: [TranscriptSearchEntry]) throws {
        guard let db else { return }
        try Self.exec(db, "BEGIN IMMEDIATE")
        do {
            try deleteMessages(db, sessionID: sessionID)
            let insert = "INSERT INTO messages (session_id, item_id, role, ordinal, text) VALUES (?1, ?2, ?3, ?4, ?5)"
            let insertFTS = "INSERT INTO messages_fts (rowid, text) VALUES (last_insert_rowid(), ?1)"
            let messageStatement = try Self.prepare(db, insert)
            let ftsStatement = try Self.prepare(db, insertFTS)
            defer {
                sqlite3_finalize(messageStatement)
                sqlite3_finalize(ftsStatement)
            }
            for entry in entries {
                sqlite3_reset(messageStatement)
                Self.bind(messageStatement, 1, sessionID)
                Self.bind(messageStatement, 2, entry.itemID)
                Self.bind(messageStatement, 3, entry.role.rawValue)
                sqlite3_bind_int64(messageStatement, 4, Int64(entry.ordinal))
                Self.bind(messageStatement, 5, entry.text)
                guard sqlite3_step(messageStatement) == SQLITE_DONE else { throw Self.error(db) }
                sqlite3_reset(ftsStatement)
                Self.bind(ftsStatement, 1, entry.text)
                guard sqlite3_step(ftsStatement) == SQLITE_DONE else { throw Self.error(db) }
            }
            try Self.query(db, "INSERT OR REPLACE INTO sessions (id, updated, entry_count) VALUES (?1, ?2, ?3)", bind: { statement in
                Self.bind(statement, 1, sessionID)
                sqlite3_bind_double(statement, 2, updated.timeIntervalSince1970)
                sqlite3_bind_int64(statement, 3, Int64(entries.count))
            }) { _ in }
            try Self.exec(db, "COMMIT")
        } catch {
            try? Self.exec(db, "ROLLBACK")
            throw error
        }
    }

    /// Forgets sessions (deleted, or no longer listed by any engine).
    public func remove(sessionIDs: [String]) throws {
        guard let db, !sessionIDs.isEmpty else { return }
        try Self.exec(db, "BEGIN IMMEDIATE")
        do {
            for id in sessionIDs {
                try deleteMessages(db, sessionID: id)
                try Self.query(db, "DELETE FROM sessions WHERE id = ?1", bind: { Self.bind($0, 1, id) }) { _ in }
            }
            try Self.exec(db, "COMMIT")
        } catch {
            try? Self.exec(db, "ROLLBACK")
            throw error
        }
    }

    private func deleteMessages(_ db: OpaquePointer, sessionID: String) throws {
        // External-content FTS tables are told which rows go, with the text they held.
        try Self.query(db, """
        INSERT INTO messages_fts (messages_fts, rowid, text) SELECT 'delete', rowid, text FROM messages WHERE session_id = ?1
        """, bind: { Self.bind($0, 1, sessionID) }) { _ in }
        try Self.query(db, "DELETE FROM messages WHERE session_id = ?1", bind: { Self.bind($0, 1, sessionID) }) { _ in }
    }

    // MARK: SQLite helpers

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private static func bind(_ statement: OpaquePointer, _ index: Int32, _ value: String) {
        sqlite3_bind_text(statement, index, value, -1, transient)
    }

    private static func text(_ statement: OpaquePointer, _ column: Int32) -> String {
        guard let pointer = sqlite3_column_text(statement, column) else { return "" }
        return String(cString: pointer)
    }

    private static func error(_ db: OpaquePointer) -> IndexError {
        .statement(String(cString: sqlite3_errmsg(db)))
    }

    private static func prepare(_ db: OpaquePointer, _ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw error(db) }
        return statement
    }

    private static func exec(_ db: OpaquePointer, _ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw error(db) }
    }

    private static func query(_ db: OpaquePointer, _ sql: String, bind: (OpaquePointer) -> Void = { _ in },
                              row: (OpaquePointer) -> Void) throws {
        let statement = try prepare(db, sql)
        defer { sqlite3_finalize(statement) }
        bind(statement)
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_ROW { row(statement); continue }
            if status == SQLITE_DONE { return }
            throw error(db)
        }
    }
}
