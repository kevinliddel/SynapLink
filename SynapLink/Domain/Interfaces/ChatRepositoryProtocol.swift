//
//  ChatRepositoryProtocol.swift
//  SynapLink
//
//  Contract for chat history persistence. The Data layer implements this
//  (ChatStore over encrypted SQLite); Presentation depends only on the
//  protocol so storage can evolve without touching the UI.
//

import Foundation

protocol ChatRepositoryProtocol: AnyObject {
    /// All chats, newest-updated first. `query` filters by title and
    /// message content (case-insensitive substring).
    func chats(matching query: String) -> [Chat]

    @discardableResult
    func createChat(title: String) -> Chat?

    func renameChat(id: Int64, title: String)
    /// Record that the model has titled this chat (suppresses re-titling).
    func markChatAutoTitled(id: Int64)
    func deleteChat(id: Int64)
    func touchChat(id: Int64)

    func messages(chatID: Int64) -> [Message]

    @discardableResult
    func appendMessage(chatID: Int64, role: MessageRole, content: String) -> Message?

    /// Replace a message's content (used when a streamed reply finishes or
    /// is regenerated).
    func updateMessage(id: Int64, content: String)
    func deleteMessage(id: Int64)

    // MARK: Attachments

    /// Persist media bytes for a message (encrypted-at-rest file + DB row).
    @discardableResult
    func appendAttachment(messageID: Int64, kind: AttachmentKind, data: Data) -> Attachment?

    /// Absolute file URL for an attachment's bytes.
    func attachmentURL(_ attachment: Attachment) -> URL?

    /// Load an attachment's bytes (nil if the file vanished).
    func attachmentData(_ attachment: Attachment) -> Data?
}
