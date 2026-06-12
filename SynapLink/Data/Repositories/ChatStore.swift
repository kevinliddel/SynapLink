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
        // Collect attachment files before the cascade wipes their rows.
        let fileNames = db.query("""
            SELECT a.file_name FROM attachments a
            JOIN messages m ON m.id = a.message_id WHERE m.chat_id = ?
            """, [.int(id)]) { stmt in ChatDatabase.text(stmt, 0) }
        db.run("DELETE FROM chats WHERE id = ?", [.int(id)])
        removeAttachmentFiles(fileNames)
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
        var messages = db.query(
            "SELECT id, chat_id, role, content, created_at FROM messages WHERE chat_id = ? ORDER BY id",
            [.int(chatID)]
        ) { stmt in
            Message(id: ChatDatabase.int64(stmt, 0),
                    chatID: ChatDatabase.int64(stmt, 1),
                    role: MessageRole(rawValue: ChatDatabase.text(stmt, 2)) ?? .user,
                    content: ChatDatabase.text(stmt, 3),
                    createdAt: Date(timeIntervalSince1970: ChatDatabase.double(stmt, 4)))
        }

        // One query for the whole chat's attachments, grouped onto messages.
        let attachments = db.query("""
            SELECT a.id, a.message_id, a.kind, a.file_name FROM attachments a
            JOIN messages m ON m.id = a.message_id WHERE m.chat_id = ? ORDER BY a.id
            """, [.int(chatID)]) { stmt in
            Attachment(id: ChatDatabase.int64(stmt, 0),
                       messageID: ChatDatabase.int64(stmt, 1),
                       kind: AttachmentKind(rawValue: ChatDatabase.text(stmt, 2)) ?? .image,
                       fileName: ChatDatabase.text(stmt, 3))
        }
        guard !attachments.isEmpty else { return messages }
        let byMessage = Dictionary(grouping: attachments, by: \.messageID)
        for index in messages.indices {
            messages[index].attachments = byMessage[messages[index].id] ?? []
        }
        return messages
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
        let fileNames = db.query("SELECT file_name FROM attachments WHERE message_id = ?",
                                 [.int(id)]) { stmt in ChatDatabase.text(stmt, 0) }
        db.run("DELETE FROM messages WHERE id = ?", [.int(id)])
        removeAttachmentFiles(fileNames)
        mutated()
    }

    // MARK: - Attachments

    private static func attachmentsDirectory() -> URL? {
        guard let base = try? ProtectedStorage.privateApplicationSupportURL() else { return nil }
        let dir = base.appendingPathComponent("attachments", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(
                at: dir, withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.complete])
        }
        return dir
    }

    @discardableResult
    func appendAttachment(messageID: Int64, kind: AttachmentKind, data: Data) -> Attachment? {
        guard let db = database, let dir = Self.attachmentsDirectory() else { return nil }
        let ext = kind == .image ? "jpg" : "wav"
        let fileName = "\(UUID().uuidString).\(ext)"
        let url = dir.appendingPathComponent(fileName)
        do {
            try data.write(to: url, options: [.atomic, .completeFileProtection])
        } catch {
            return nil
        }
        guard db.run("INSERT INTO attachments (message_id, kind, file_name, created_at) VALUES (?, ?, ?, ?)",
                     [.int(messageID), .text(kind.rawValue), .text(fileName),
                      .real(Date().timeIntervalSince1970)]) else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        mutated()
        return Attachment(id: db.lastInsertRowID, messageID: messageID, kind: kind, fileName: fileName)
    }

    func attachmentURL(_ attachment: Attachment) -> URL? {
        Self.attachmentsDirectory()?.appendingPathComponent(attachment.fileName)
    }

    func attachmentData(_ attachment: Attachment) -> Data? {
        guard let url = attachmentURL(attachment) else { return nil }
        return try? Data(contentsOf: url)
    }

    private func removeAttachmentFiles(_ fileNames: [String]) {
        guard !fileNames.isEmpty, let dir = Self.attachmentsDirectory() else { return }
        for name in fileNames {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
        }
    }
}
