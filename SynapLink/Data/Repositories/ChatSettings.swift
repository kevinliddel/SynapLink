//
//  ChatSettings.swift
//  SynapLink
//
//  User-tunable chat behavior, persisted to UserDefaults (NeuraLink
//  UserSettings pattern).
//

import Foundation
import Observation

@Observable
final class ChatSettings {

    static let shared = ChatSettings()

    private static let systemPromptKey = "com.synaplink.chat.systemPrompt"
    private static let maxNewTokensKey = "com.synaplink.chat.maxNewTokens"

    static let defaultSystemPrompt = """
    You are SynapLink, a helpful assistant running fully offline on the \
    user's iPhone. Be concise and direct. Never claim to access the \
    internet — you have no network connection.
    """

    var systemPrompt: String {
        didSet { UserDefaults.standard.set(systemPrompt, forKey: Self.systemPromptKey) }
    }

    var maxNewTokens: Int {
        didSet { UserDefaults.standard.set(maxNewTokens, forKey: Self.maxNewTokensKey) }
    }

    private init() {
        systemPrompt = UserDefaults.standard.string(forKey: Self.systemPromptKey)
            ?? Self.defaultSystemPrompt
        let stored = UserDefaults.standard.integer(forKey: Self.maxNewTokensKey)
        maxNewTokens = stored > 0 ? stored : 512
    }

    func resetSystemPrompt() {
        systemPrompt = Self.defaultSystemPrompt
    }
}
