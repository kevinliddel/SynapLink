//
//  ChatStore.swift
//  SynapLink
//
//  Chat history repository over the encrypted SQLite database. @Observable
//  singleton (NeuraLink repository pattern): views observe `lastUpdated`
//  and re-query on change.
//

import Foundation
import Observation

@MainActor
@Observable
final class ChatStore: ChatRepositoryProtocol {

    static let shared = ChatStore()

    /// Bumped on every mutation; observing views re-render and re-query.
    private(set) var lastUpdated = Date()

    @ObservationIgnored private var database: ChatDatabase?

    private init() {
        if let dir = try? ProtectedStorage.privateApplicationSupportURL() {
            database = ChatDatabase(directory: dir)
        }
    }

    private func mutated() {
        database?.protectFamily()
        lastUpdated = Date()
    }

    // MARK: - Chats

    func chats(matching query: String) -> [Chat] {
        guard let db = database else { return [] }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let sql: String
        var bindings: [SQLiteValue] = []
        if trimmed.isEmpty {
            sql = "SELECT id, title, created_at, updated_at FROM chats ORDER BY updated_at DESC"
        } else {
            sql = """
            SELECT DISTINCT c.id, c.title, c.created_at, c.updated_at FROM chats c
            LEFT JOIN messages m ON m.chat_id = c.id
            WHERE c.title LIKE '%' || ?1 || '%' COLLATE NOCASE
               OR m.content LIKE '%' || ?1 || '%' COLLATE NOCASE
            ORDER BY c.updated_at DESC
            """
            bindings = [.text(trimmed)]
        }
        return db.query(sql, bindings) { stmt in
            Chat(id: ChatDatabase.int64(stmt, 0),
                 title: ChatDatabase.text(stmt, 1),
                 createdAt: Date(timeIntervalSince1970: ChatDatabase.double(stmt, 2)),
                 updatedAt: Date(timeIntervalSince1970: ChatDatabase.double(stmt, 3)))
        }
    }

    @discardableResult
    func createChat(title: String) -> Chat? {
        guard let db = database else { return nil }
        let now = Date()
        guard db.run("INSERT INTO chats (title, created_at, updated_at) VALUES (?, ?, ?)",
                     [.text(title), .real(now.timeIntervalSince1970), .real(now.timeIntervalSince1970)]) else {
            return nil
        }
        mutated()
        return Chat(id: db.lastInsertRowID, title: title, createdAt: now, updatedAt: now)
    }

    func renameChat(id: Int64, title: String) {
        guard let db = database else { return }
        db.run("UPDATE chats SET title = ? WHERE id = ?", [.text(title), .int(id)])
        mutated()
    }

    func deleteChat(id: Int64) {
        guard let db = database else { return }
        db.run("DELETE FROM chats WHERE id = ?", [.int(id)])
        mutated()
    }

    func touchChat(id: Int64) {
        guard let db = database else { return }
        db.run("UPDATE chats SET updated_at = ? WHERE id = ?",
               [.real(Date().timeIntervalSince1970), .int(id)])
        mutated()
    }

    // MARK: - Messages

    func messages(chatID: Int64) -> [Message] {
        guard let db = database else { return [] }
        return db.query(
            "SELECT id, chat_id, role, content, created_at FROM messages WHERE chat_id = ? ORDER BY id",
            [.int(chatID)]
        ) { stmt in
            Message(id: ChatDatabase.int64(stmt, 0),
                    chatID: ChatDatabase.int64(stmt, 1),
                    role: MessageRole(rawValue: ChatDatabase.text(stmt, 2)) ?? .user,
                    content: ChatDatabase.text(stmt, 3),
                    createdAt: Date(timeIntervalSince1970: ChatDatabase.double(stmt, 4)))
        }
    }

    /// Most recent message of a chat — used for list previews.
    func lastMessage(chatID: Int64) -> Message? {
        guard let db = database else { return nil }
        return db.query(
            "SELECT id, chat_id, role, content, created_at FROM messages WHERE chat_id = ? ORDER BY id DESC LIMIT 1",
            [.int(chatID)]
        ) { stmt in
            Message(id: ChatDatabase.int64(stmt, 0),
                    chatID: ChatDatabase.int64(stmt, 1),
                    role: MessageRole(rawValue: ChatDatabase.text(stmt, 2)) ?? .user,
                    content: ChatDatabase.text(stmt, 3),
                    createdAt: Date(timeIntervalSince1970: ChatDatabase.double(stmt, 4)))
        }.first
    }

    @discardableResult
    func appendMessage(chatID: Int64, role: MessageRole, content: String) -> Message? {
        guard let db = database else { return nil }
        let now = Date()
        guard db.run("INSERT INTO messages (chat_id, role, content, created_at) VALUES (?, ?, ?, ?)",
                     [.int(chatID), .text(role.rawValue), .text(content),
                      .real(now.timeIntervalSince1970)]) else {
            return nil
        }
        db.run("UPDATE chats SET updated_at = ? WHERE id = ?",
               [.real(now.timeIntervalSince1970), .int(chatID)])
        mutated()
        return Message(id: db.lastInsertRowID, chatID: chatID, role: role,
                       content: content, createdAt: now)
    }

    func updateMessage(id: Int64, content: String) {
        guard let db = database else { return }
        db.run("UPDATE messages SET content = ? WHERE id = ?", [.text(content), .int(id)])
        mutated()
    }

    func deleteMessage(id: Int64) {
        guard let db = database else { return }
        db.run("DELETE FROM messages WHERE id = ?", [.int(id)])
        mutated()
    }
}
