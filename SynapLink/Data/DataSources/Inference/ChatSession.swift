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
#if canImport(UIKit)
import UIKit
#endif

enum EngineState: Equatable {
    case unloaded
    case loading
    case ready(description: String)
    case failed(message: String)
}

/// Media captured for the turn being sent; persisted to the encrypted
/// attachment store by `ChatSession.send`.
struct PendingAttachment {
    let kind: AttachmentKind
    let data: Data
}

extension AttachmentKind {
    var placeholder: String {
        switch self {
        case .image: return "Photo"
        case .audio: return "Voice note"
        }
    }
}

@MainActor
@Observable
final class ChatSession {

    static let shared = ChatSession()

    private(set) var engineState: EngineState = .unloaded
    private(set) var capabilities: EngineCapabilities?
    private(set) var activeChat: Chat?
    private(set) var messages: [Message] = []
    private(set) var streamingText = ""
    private(set) var isGenerating = false
    /// True while a media turn is in its encode/prefill stage (no tokens
    /// yet) — image encode alone takes seconds; the UI shows an affordance.
    private(set) var isAnalyzingMedia = false
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

    private init() {
        // Memory pressure: drop the KV cache before jetsam drops us. The
        // next turn re-prefills from scratch — slow but alive.
        #if canImport(UIKit)
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil, queue: .main
        ) { _ in
            Task { @MainActor in
                ChatSession.shared.handleMemoryWarning()
            }
        }
        #endif
    }

    private func handleMemoryWarning() {
        guard !isGenerating else { return }  // mid-decode the cache is live
        Task { await engine.clearKVCache() }
    }

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
        // Hard gate before touching the engine: loading an oversized model
        // doesn't fail gracefully — Metal over-allocates and jetsam kills
        // the whole app (observed with E2B on iPhone 11).
        guard config.isSupportedOnThisDevice else {
            engineState = .failed(message:
                "\(config.rawValue) needs ≥\(Int(config.requiredRAMGB)) GB RAM and can't run on this device. Pick a smaller model in the Model Library.")
            return
        }
        guard let modelURL = config.modelURL() else {
            engineState = .failed(message: "Model not downloaded. Open the Model Library to download it.")
            return
        }
        let params = RuntimeProfile.engineParams(
            modelPath: modelURL.path, mmprojPath: config.mmprojURL()?.path)
        do {
            let caps = try await engine.load(params)
            loadedNCtx = Int(caps.nCtx)
            capabilities = caps
            engineState = .ready(description: caps.modelDescription)
        } catch {
            engineState = .failed(message: error.localizedDescription)
        }
    }

    func unloadEngine() async {
        stop()
        await engine.unload()
        capabilities = nil
        engineState = .unloaded
    }

    // MARK: - Turns

    func send(_ text: String, attachments: [PendingAttachment] = []) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty,
              !isGenerating, let chat = activeChat else { return }

        guard var saved = store.appendMessage(chatID: chat.id, role: .user, content: trimmed) else { return }
        // Bytes go to the encrypted attachment store; history renders the
        // real thumbnail/player from there, and regenerate can re-send them.
        for attachment in attachments {
            if let row = store.appendAttachment(
                messageID: saved.id, kind: attachment.kind, data: attachment.data) {
                saved.attachments.append(row)
            }
        }
        messages.append(saved)
        autoTitleIfNeeded(chat: chat,
                          firstUserText: trimmed.isEmpty
                              ? attachments.map(\.kind.placeholder).joined(separator: " ")
                              : trimmed)
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

        // The current turn's media comes from the last user message's STORED
        // attachments — the same path serves fresh sends and regenerates.
        let lastUser = messages.last(where: { $0.role == .user })
        let mediaData = lastUser?.attachments.compactMap { store.attachmentData($0) } ?? []
        isAnalyzingMedia = !mediaData.isEmpty

        generationTask = Task { [weak self] in
            guard let self else { return }
            await self.ensureEngineLoaded()
            guard case .ready = self.engineState else {
                self.isGenerating = false
                self.isAnalyzingMedia = false
                return
            }
            do {
                var history = self.trimmedHistory()
                // Media turn: the engine replaces one marker per attachment
                // with encoded image/audio chunks (mtmd_tokenize); markers
                // exist only in the prompt, never in persisted content.
                if !mediaData.isEmpty, let lastIndex = history.lastIndex(where: { $0.role == "user" }) {
                    let markers = String(repeating: InferenceEngine.mediaMarker, count: mediaData.count)
                    history[lastIndex].content = markers + (lastUser?.content ?? "")
                }
                let prompt = try await self.engine.applyChatTemplate(history)
                for try await piece in self.engine.generate(
                    prompt: prompt,
                    media: mediaData,
                    maxNewTokens: Int32(self.settings.maxNewTokens)) {
                    self.isAnalyzingMedia = false
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
            self.isAnalyzingMedia = false

            await self.generateTitleIfDue(for: chat)
        }
    }

    // MARK: - Model-generated chat title

    /// Once the conversation has ≥5 messages, ask the model itself for a
    /// short title (one-shot per chat — the `autoTitled` flag persists).
    /// The request appends a single instruction turn to the existing
    /// conversation, so the engine's prefix reuse makes it nearly free.
    private func generateTitleIfDue(for chat: Chat) async {
        guard let current = activeChat, current.id == chat.id,
              !current.autoTitled, messages.count >= 5,
              !isGenerating, case .ready = engineState else { return }

        var history = trimmedHistory()
        history.append(ChatMessage(
            role: "user",
            content: "Summarize our conversation above as a title of at most six words. " +
                     "Reply with ONLY the title itself — no quotes, no trailing punctuation."))
        guard let prompt = try? await engine.applyChatTemplate(history) else { return }

        var raw = ""
        do {
            for try await piece in engine.generate(prompt: prompt, maxNewTokens: 16) {
                raw += piece
            }
        } catch {
            return  // cosmetic feature — never surface errors for it
        }

        guard let title = Self.cleanTitle(raw), activeChat?.id == chat.id else { return }
        store.renameChat(id: chat.id, title: title)
        store.markChatAutoTitled(id: chat.id)
        activeChat?.title = title
        activeChat?.autoTitled = true
    }

    /// First line, stripped of quotes/labels; rejects empty or rambling output.
    static func cleanTitle(_ raw: String) -> String? {
        var title = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let newline = title.firstIndex(of: "\n") {
            title = String(title[..<newline])
        }
        for prefix in ["Title:", "title:"] where title.hasPrefix(prefix) {
            title = String(title.dropFirst(prefix.count))
        }
        title = title.trimmingCharacters(in: CharacterSet(charactersIn: " \"'“”‘’.!,*#"))
        guard !title.isEmpty, title.count <= 60 else { return nil }
        return title
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
