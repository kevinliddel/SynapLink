//
//  ChatSession.swift
//  SynapLink
//
//  The Swift service that owns a conversation in progress (PLAN.md §3):
//  loads the engine for the selected model, formats history with the model's
//  own chat template, trims to the context budget, streams the reply, and
//  persists turns. KV/prompt-cache reuse across turns comes for free: each
//  turn re-sends the full templated conversation, and the engine's
//  longest-common-prefix prefill only decodes the new suffix.
//

import Foundation
import Observation

enum EngineState: Equatable {
    case unloaded
    case loading
    case ready(description: String)
    case failed(message: String)
}

@MainActor
@Observable
final class ChatSession {

    static let shared = ChatSession()

    private(set) var engineState: EngineState = .unloaded
    private(set) var activeChat: Chat?
    private(set) var messages: [Message] = []
    private(set) var streamingText = ""
    private(set) var isGenerating = false
    private(set) var lastError: String?

    @ObservationIgnored private let engine = InferenceEngine.shared
    @ObservationIgnored private let store: ChatRepositoryProtocol = ChatStore.shared
    @ObservationIgnored private let settings = ChatSettings.shared
    @ObservationIgnored private var generationTask: Task<Void, Never>?
    @ObservationIgnored private var loadedNCtx: Int = 2048

    /// Token-estimation heuristic: ~3.5 UTF-8 bytes/token (NeuraLink's
    /// empirically tuned value) + per-message template overhead.
    private static let bytesPerToken = 3.5
    private static let tokensPerMessageOverhead = 10

    private init() {}

    // MARK: - Chat lifecycle

    func open(chat: Chat) {
        if isGenerating { stop() }
        activeChat = chat
        messages = store.messages(chatID: chat.id)
        streamingText = ""
        lastError = nil
    }

    func startNewChat() -> Chat? {
        guard let chat = store.createChat(title: "New Chat") else { return nil }
        open(chat: chat)
        return chat
    }

    // MARK: - Engine lifecycle

    func ensureEngineLoaded() async {
        guard !engine.isLoaded else { return }
        if case .loading = engineState { return }

        engineState = .loading
        let config = ModelDownloadManager.shared.selectedConfig
        guard let modelURL = config.modelURL() else {
            engineState = .failed(message: "Model not downloaded. Open the Model Library to download it.")
            return
        }
        var params = EngineParams(modelPath: modelURL.path)
        params.mmprojPath = config.mmprojURL()?.path
        do {
            let caps = try await engine.load(params)
            loadedNCtx = Int(caps.nCtx)
            engineState = .ready(description: caps.modelDescription)
        } catch {
            engineState = .failed(message: error.localizedDescription)
        }
    }

    func unloadEngine() async {
        stop()
        await engine.unload()
        engineState = .unloaded
    }

    // MARK: - Turns

    func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isGenerating, let chat = activeChat else { return }

        if let saved = store.appendMessage(chatID: chat.id, role: .user, content: trimmed) {
            messages.append(saved)
        }
        autoTitleIfNeeded(chat: chat, firstUserText: trimmed)
        generate()
    }

    /// Drop the last assistant reply and produce a new one for the same
    /// user turn.
    func regenerate() {
        guard !isGenerating, activeChat != nil,
              let last = messages.last, last.role == .assistant else { return }
        store.deleteMessage(id: last.id)
        messages.removeLast()
        generate()
    }

    func stop() {
        engine.cancel()
    }

    private func generate() {
        guard let chat = activeChat else { return }
        isGenerating = true
        streamingText = ""
        lastError = nil

        generationTask = Task { [weak self] in
            guard let self else { return }
            await self.ensureEngineLoaded()
            guard case .ready = self.engineState else {
                self.isGenerating = false
                return
            }
            do {
                let history = self.trimmedHistory()
                let prompt = try await self.engine.applyChatTemplate(history)
                for try await piece in self.engine.generate(
                    prompt: prompt, maxNewTokens: Int32(self.settings.maxNewTokens)) {
                    self.streamingText += piece
                }
            } catch {
                self.lastError = error.localizedDescription
            }

            let reply = self.streamingText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !reply.isEmpty, self.activeChat?.id == chat.id {
                if let saved = self.store.appendMessage(chatID: chat.id, role: .assistant, content: reply) {
                    self.messages.append(saved)
                }
            }
            self.streamingText = ""
            self.isGenerating = false
        }
    }

    // MARK: - Context-window trimming

    /// System prompt + sliding window of the most recent turns that fit the
    /// budget (PLAN.md Phase 1 policy; summarize-on-overflow comes later).
    /// The newest user message is always included even if it alone busts the
    /// budget — the engine clamps the rest.
    private func trimmedHistory() -> [ChatMessage] {
        let budget = max(256, Int(Double(loadedNCtx - settings.maxNewTokens) * 0.85))

        var result: [ChatMessage] = []
        var used = estimateTokens(settings.systemPrompt)

        var window: [ChatMessage] = []
        for message in messages.reversed() {
            let cost = estimateTokens(message.content)
            if used + cost > budget && !window.isEmpty { break }
            used += cost
            window.append(ChatMessage(role: message.role.rawValue, content: message.content))
        }

        result.append(ChatMessage(role: "system", content: settings.systemPrompt))
        result.append(contentsOf: window.reversed())
        return result
    }

    private func estimateTokens(_ text: String) -> Int {
        Int(Double(text.utf8.count) / Self.bytesPerToken) + Self.tokensPerMessageOverhead
    }

    private func autoTitleIfNeeded(chat: Chat, firstUserText: String) {
        guard chat.title == "New Chat" else { return }
        let title = String(firstUserText.prefix(48))
        store.renameChat(id: chat.id, title: title)
        activeChat?.title = title
    }
}
