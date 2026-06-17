//
//  ChatSession+Topics.swift
//  SynapLink
//
//  Home "Popular topics" generation. A one-off prompt to the loaded chat model,
//  separate from the conversation flow — kept out of ChatSession.swift to keep
//  that file focused on the live turn loop.
//

import Foundation

extension ChatSession {

    /// Ask the model for a few short, varied topics to surface on Home. Reuses
    /// the loaded engine (warming it for the first real chat). Returns [] on any
    /// failure — purely decorative.
    func suggestTopics(count: Int = 5) async -> [String] {
        await ensureEngineLoaded()
        guard case .ready = engineState, !isGenerating else { return [] }

        let messages = [
            ChatMessage(role: "system",
                        content: "You suggest short, intriguing topics for an AI chat app."),
            ChatMessage(role: "user",
                        content: "List \(count) diverse topics someone might enjoy exploring with "
                            + "an AI assistant — mix science, history, technology, culture, health, "
                            + "and everyday curiosity. Each must be 2 to 5 words. No numbering, no "
                            + "explanations, no end punctuation. Output exactly one topic per line.")
        ]
        let engine = InferenceEngine.shared
        guard let prompt = try? await engine.applyChatTemplate(messages) else { return [] }

        var raw = ""
        do {
            for try await piece in engine.generate(prompt: prompt, maxNewTokens: 128) {
                raw += piece
            }
        } catch {
            return []  // decorative — never surface errors for it
        }
        return Self.parseTopics(raw, limit: count)
    }

    /// One topic per line, stripped of bullets/numbering/quotes; deduped.
    static func parseTopics(_ raw: String, limit: Int) -> [String] {
        var topics: [String] = []
        for line in raw.split(whereSeparator: \.isNewline) {
            var item = line.trimmingCharacters(in: .whitespaces)
            item = item.replacingOccurrences(of: "^[-*•+]+\\s*", with: "", options: .regularExpression)
            item = item.replacingOccurrences(of: "^\\d+[.)]\\s*", with: "", options: .regularExpression)
            item = item.trimmingCharacters(in: CharacterSet(charactersIn: " \"'“”‘’.!,*#`:-"))
            guard item.count >= 2, item.count <= 42 else { continue }
            if !topics.contains(where: { $0.caseInsensitiveCompare(item) == .orderedSame }) {
                topics.append(item)
            }
            if topics.count == limit { break }
        }
        return topics
    }
}
