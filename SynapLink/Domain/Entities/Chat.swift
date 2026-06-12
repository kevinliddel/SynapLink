//
//  Chat.swift
//  SynapLink
//
//  Domain entities for chat history. Pure data — no persistence or UI concerns.
//

import Foundation

struct Chat: Identifiable, Hashable, Sendable {
    var id: Int64
    var title: String
    var createdAt: Date
    var updatedAt: Date
}

enum MessageRole: String, Sendable {
    case system
    case user
    case assistant
}

struct Message: Identifiable, Equatable, Sendable {
    var id: Int64
    var chatID: Int64
    var role: MessageRole
    var content: String
    var createdAt: Date
    var attachments: [Attachment] = []
}

enum AttachmentKind: String, Sendable {
    case image
    case audio
}

/// A media file tied to a message. Bytes live as files in the protected
/// attachments directory; the DB row stores the relative file name.
struct Attachment: Identifiable, Equatable, Sendable {
    var id: Int64
    var messageID: Int64
    var kind: AttachmentKind
    var fileName: String
}
