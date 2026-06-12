//
//  ChatDatabase.swift
//  SynapLink
//
//  Thin sqlite3 wrapper for the chat history store. Raw C API (no GRDB /
//  SwiftData) — same choice as NeuraLink's MemoryStore. The DB file lives in
//  the protected private directory (NSFileProtectionComplete + no iCloud
//  backup); the journal/WAL siblings get the same protection class.
//
//  Not thread-safe by itself: ChatStore serializes access on the main actor.
//

import Foundation
import SQLite3

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum SQLiteValue {
    case int(Int64)
    case real(Double)
    case text(String)
    case null
}

final class ChatDatabase {

    private var db: OpaquePointer?
    private let path: String

    var lastInsertRowID: Int64 { sqlite3_last_insert_rowid(db) }

    init?(directory: URL, fileName: String = "synaplink_chats.sqlite") {
        let url = directory.appendingPathComponent(fileName)
        path = url.path
        guard sqlite3_open(path, &db) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        _ = run("PRAGMA foreign_keys = ON")
        _ = run("PRAGMA journal_mode = WAL")
        guard migrate() else {
            sqlite3_close(db)
            return nil
        }
        protectFamily()
    }

    deinit {
        sqlite3_close(db)
    }

    private func migrate() -> Bool {
        run("""
        CREATE TABLE IF NOT EXISTS chats (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            title TEXT NOT NULL,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL
        );
        """) && run("""
        CREATE TABLE IF NOT EXISTS messages (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            chat_id INTEGER NOT NULL REFERENCES chats(id) ON DELETE CASCADE,
            role TEXT NOT NULL,
            content TEXT NOT NULL,
            created_at REAL NOT NULL
        );
        """) && run("CREATE INDEX IF NOT EXISTS idx_messages_chat ON messages(chat_id, id);") && run("""
        CREATE TABLE IF NOT EXISTS attachments (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            message_id INTEGER NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
            kind TEXT NOT NULL,
            file_name TEXT NOT NULL,
            created_at REAL NOT NULL
        );
        """) && run("CREATE INDEX IF NOT EXISTS idx_attachments_message ON attachments(message_id);")
    }

    /// The -wal/-shm/-journal siblings appear after first write; re-applying
    /// protection is cheap, so callers can invoke this after mutations too.
    func protectFamily() {
        for suffix in ["", "-wal", "-shm", "-journal"] {
            ProtectedStorage.protect(URL(fileURLWithPath: path + suffix))
        }
    }

    // MARK: - Statement helpers

    @discardableResult
    func run(_ sql: String, _ bindings: [SQLiteValue] = []) -> Bool {
        guard let stmt = prepare(sql, bindings) else { return false }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_DONE
    }

    /// Execute a query and map each result row through `transform`, which
    /// reads columns by index from the live statement.
    func query<T>(_ sql: String, _ bindings: [SQLiteValue] = [],
                  transform: (OpaquePointer) -> T?) -> [T] {
        guard let stmt = prepare(sql, bindings) else { return [] }
        defer { sqlite3_finalize(stmt) }
        var results: [T] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let value = transform(stmt) {
                results.append(value)
            }
        }
        return results
    }

    private func prepare(_ sql: String, _ bindings: [SQLiteValue]) -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return nil
        }
        for (index, value) in bindings.enumerated() {
            let position = Int32(index + 1)
            switch value {
            case .int(let v): sqlite3_bind_int64(stmt, position, v)
            case .real(let v): sqlite3_bind_double(stmt, position, v)
            case .text(let v): sqlite3_bind_text(stmt, position, v, -1, sqliteTransient)
            case .null: sqlite3_bind_null(stmt, position)
            }
        }
        return stmt
    }

    // MARK: - Column readers (for use inside `transform`)

    static func int64(_ stmt: OpaquePointer, _ column: Int32) -> Int64 {
        sqlite3_column_int64(stmt, column)
    }

    static func double(_ stmt: OpaquePointer, _ column: Int32) -> Double {
        sqlite3_column_double(stmt, column)
    }

    static func text(_ stmt: OpaquePointer, _ column: Int32) -> String {
        guard let cString = sqlite3_column_text(stmt, column) else { return "" }
        return String(cString: cString)
    }
}
