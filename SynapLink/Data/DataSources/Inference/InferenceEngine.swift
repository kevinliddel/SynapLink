//
//  InferenceEngine.swift
//  SynapLink
//
//  The single serialized owner of the C++ inference core
//  (One inference actor, no concurrent contexts on 4 GB).
//
//  All blocking C calls run on a dedicated serial DispatchQueue — not on the
//  Swift cooperative thread pool, which must never be blocked for seconds.
//  `cancel()` is the one exception: it only flips an atomic flag in C and is
//  safe from any thread, which is exactly what lets it interrupt a generate
//  call that is busy on the engine queue.
//

import Foundation

enum InferenceEngineError: Error, LocalizedError {
    case alreadyLoaded
    case notLoaded
    case loadFailed(model: String)
    case generationFailed(code: Int32)
    case templateFailed

    var errorDescription: String? {
        switch self {
        case .alreadyLoaded:
            return "A model is already loaded — unload it first."
        case .notLoaded:
            return "No model is loaded."
        case .loadFailed(let model):
            return "Failed to load model: \(model)"
        case .generationFailed(let code):
            return "Generation failed (engine error \(code))."
        case .templateFailed:
            return "Failed to apply the model's chat template."
        }
    }
}

struct ChatMessage: Sendable {
    var role: String  // "system" | "user" | "assistant"
    var content: String
}

/// Capabilities reported by the loaded model + projector.
struct EngineCapabilities: Sendable {
    var modelDescription: String
    var hasVision: Bool
    var hasAudio: Bool
    var audioSampleRate: Int32  // -1 when audio unsupported
    var nCtx: Int32
}

final class InferenceEngine: @unchecked Sendable {

    static let shared = InferenceEngine()

    private let queue = DispatchQueue(
        label: "com.dedicatus.synaplink.inference", qos: .userInitiated)
    private let handleLock = NSLock()
    private var _handle: OpaquePointer?

    /// The media marker the prompt must contain once per media attachment.
    static var mediaMarker: String { String(cString: synap_engine_media_marker()) }

    private init() {}

    deinit {
        if let h = currentHandle() { synap_engine_free(h) }
    }

    private func currentHandle() -> OpaquePointer? {
        handleLock.lock()
        defer { handleLock.unlock() }
        return _handle
    }

    private func setHandle(_ handle: OpaquePointer?) {
        handleLock.lock()
        defer { handleLock.unlock() }
        _handle = handle
    }

    var isLoaded: Bool { currentHandle() != nil }

    // MARK: - Lifecycle

    /// Load a model (and optional mmproj). Heavy: seconds of disk + Metal work.
    func load(_ params: EngineParams) async throws -> EngineCapabilities {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                guard currentHandle() == nil else {
                    continuation.resume(throwing: InferenceEngineError.alreadyLoaded)
                    return
                }
                let handle = params.withCParams { cParams in
                    withUnsafePointer(to: cParams) { synap_engine_create($0) }
                }
                guard let handle else {
                    continuation.resume(
                        throwing: InferenceEngineError.loadFailed(
                            model: (params.modelPath as NSString).lastPathComponent))
                    return
                }
                setHandle(handle)
                continuation.resume(returning: capabilities(of: handle))
            }
        }
    }

    func unload() async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                if let handle = currentHandle() {
                    setHandle(nil)
                    synap_engine_free(handle)
                }
                continuation.resume()
            }
        }
    }

    private func capabilities(of handle: OpaquePointer) -> EngineCapabilities {
        var descBuf = [CChar](repeating: 0, count: 256)
        _ = synap_engine_model_desc(handle, &descBuf, Int32(descBuf.count))
        return EngineCapabilities(
            modelDescription: String(cString: descBuf),
            hasVision: synap_engine_has_vision(handle),
            hasAudio: synap_engine_has_audio(handle),
            audioSampleRate: synap_engine_audio_sample_rate(handle),
            nCtx: synap_engine_n_ctx(handle))
    }

    // MARK: - Generation

    private final class TokenSink {
        let onPiece: (String) -> Bool
        init(onPiece: @escaping (String) -> Bool) { self.onPiece = onPiece }
    }

    /// Stream a response for a fully-templated prompt. `media` buffers are the
    /// raw bytes of encoded files (jpg/png / wav/mp3/flac); the prompt must
    /// contain `Self.mediaMarker` once per buffer.
    ///
    /// Cancelling the consuming task cancels generation; the stream then
    /// finishes normally with the tokens produced so far.
    func generate(
        prompt: String,
        media: [Data] = [],
        maxNewTokens: Int32 = 512
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            continuation.onTermination = { [weak self] termination in
                if case .cancelled = termination { self?.cancel() }
            }
            queue.async { [self] in
                guard let handle = currentHandle() else {
                    continuation.finish(throwing: InferenceEngineError.notLoaded)
                    return
                }
                let sink = TokenSink { piece in
                    continuation.yield(piece)
                    return true  // stop requests arrive via synap_engine_cancel
                }
                let rc = withExtendedLifetime(sink) {
                    Self.withMediaInputs(media) { inputs -> Int32 in
                        synap_engine_generate(
                            handle, prompt,
                            inputs.isEmpty ? nil : inputs, Int32(inputs.count),
                            maxNewTokens,
                            { cPiece, userData in
                                guard let cPiece, let userData else { return false }
                                let sink = Unmanaged<TokenSink>.fromOpaque(userData)
                                    .takeUnretainedValue()
                                return sink.onPiece(String(cString: cPiece))
                            },
                            Unmanaged.passUnretained(sink).toOpaque())
                    }
                }
                if rc == 0 {
                    continuation.finish()
                } else {
                    continuation.finish(throwing: InferenceEngineError.generationFailed(code: rc))
                }
            }
        }
    }

    /// Ask the running generation to stop after the current token.
    /// Safe from any thread; no-op when idle.
    func cancel() {
        if let handle = currentHandle() { synap_engine_cancel(handle) }
    }

    /// Drop the KV cache (memory-pressure escape hatch). Serialized behind
    /// any in-flight generate call.
    func clearKVCache() async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                if let handle = currentHandle() { synap_engine_clear_kv(handle) }
                continuation.resume()
            }
        }
    }

    /// Telemetry from the most recent completed generate call.
    func stats() async -> GenerationStats {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                guard let handle = currentHandle() else {
                    continuation.resume(returning: GenerationStats())
                    return
                }
                var cStats = SynapGenStats()
                synap_engine_get_stats(handle, &cStats)
                continuation.resume(returning: GenerationStats(c: cStats))
            }
        }
    }

    // MARK: - Chat template

    /// Format messages with the model's built-in chat template (no hand-rolled
    /// template strings that drift between model versions).
    func applyChatTemplate(
        _ messages: [ChatMessage],
        addGenerationPrompt: Bool = true
    ) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                guard let handle = currentHandle() else {
                    continuation.resume(throwing: InferenceEngineError.notLoaded)
                    return
                }
                let result = Self.withCStringArrays(
                    messages.map(\.role), messages.map(\.content)
                ) { roles, contents -> String? in
                    var buf = [CChar](repeating: 0, count: 16 * 1024)
                    var written = synap_engine_apply_chat_template(
                        handle, roles, contents, Int32(messages.count),
                        addGenerationPrompt, &buf, Int32(buf.count))
                    if written >= Int32(buf.count) {
                        buf = [CChar](repeating: 0, count: Int(written) + 1)
                        written = synap_engine_apply_chat_template(
                            handle, roles, contents, Int32(messages.count),
                            addGenerationPrompt, &buf, Int32(buf.count))
                    }
                    guard written > 0 else { return nil }
                    let bytes = buf[0..<Int(written)].map { UInt8(bitPattern: $0) }
                    return String(bytes: bytes, encoding: .utf8)
                }
                if let result {
                    continuation.resume(returning: result)
                } else {
                    continuation.resume(throwing: InferenceEngineError.templateFailed)
                }
            }
        }
    }

    // MARK: - Pointer plumbing

    /// Pin `media` buffers and expose them as C media inputs for the duration
    /// of `body`.
    private static func withMediaInputs<R>(
        _ media: [Data],
        _ body: ([SynapMediaInput]) -> R
    ) -> R {
        func recurse(
            _ index: Int, _ acc: inout [SynapMediaInput],
            _ body: ([SynapMediaInput]) -> R
        ) -> R {
            if index == media.count { return body(acc) }
            return media[index].withUnsafeBytes { rawBuf in
                acc.append(
                    SynapMediaInput(
                        data: rawBuf.bindMemory(to: UInt8.self).baseAddress,
                        len: rawBuf.count))
                defer { acc.removeLast() }
                return recurse(index + 1, &acc, body)
            }
        }
        var acc: [SynapMediaInput] = []
        acc.reserveCapacity(media.count)
        return recurse(0, &acc, body)
    }

    /// Pin two string arrays as null-terminated C string arrays for `body`.
    private static func withCStringArrays<R>(
        _ a: [String], _ b: [String],
        _ body: (
            UnsafePointer<UnsafePointer<CChar>?>,
            UnsafePointer<UnsafePointer<CChar>?>
        ) -> R
    ) -> R {
        let aDup = a.map { strdup($0) }
        let bDup = b.map { strdup($0) }
        defer {
            aDup.forEach { free($0) }
            bDup.forEach { free($0) }
        }
        let aPtrs = aDup.map { UnsafePointer($0) }
        let bPtrs = bDup.map { UnsafePointer($0) }
        return aPtrs.withUnsafeBufferPointer { aBuf in
            bPtrs.withUnsafeBufferPointer { bBuf in
                body(aBuf.baseAddress!, bBuf.baseAddress!)
            }
        }
    }
}
