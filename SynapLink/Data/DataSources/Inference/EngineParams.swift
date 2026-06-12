//
//  EngineParams.swift
//  SynapLink
//
//  Swift-side configuration for the C inference engine. Defaults match the
//  iPhone 11 baseline budget (PLAN.md §1): ctx 2048, q8_0 KV + flash
//  attention, full Metal offload.
//

import Foundation

/// KV cache quantization. Raw values are ggml_type constants.
enum KVCacheType: Int32, Sendable {
    case f16 = 1
    case q4_0 = 2
    case q8_0 = 8
}

enum FlashAttention: Int32, Sendable {
    case auto = -1
    case disabled = 0
    case enabled = 1
}

struct EngineParams: Sendable {
    var modelPath: String
    var mmprojPath: String?

    var nCtx: Int32 = 2048
    var nBatch: Int32 = 512
    var nThreads: Int32 = Int32(min(4, ProcessInfo.processInfo.processorCount))
    // Proactive CPU fallback in the simulator :
    // Simulator Metal is emulated/absent and CPU is both faster and reliable there.
    // Real devices get full offload.
    #if targetEnvironment(simulator)
        var nGPULayers: Int32 = 0
    #else
        var nGPULayers: Int32 = 999
    #endif

    // Quantized KV requires flash attention enabled.
    var kvTypeK: KVCacheType = .q8_0
    var kvTypeV: KVCacheType = .q8_0
    var flashAttention: FlashAttention = .enabled

    var mmprojUseGPU: Bool = true
    var warmup: Bool = false

    var temperature: Float = 0.7
    var topP: Float = 0.9
    var topK: Int32 = 40
    var repeatPenalty: Float = 1.1
    var repeatLastN: Int32 = 64
    var seed: UInt32 = 0

    /// Bridge to the C params struct. The path C-strings are only valid for
    /// the duration of `body` — never let the pointer escape it.
    func withCParams<R>(_ body: (SynapEngineParams) throws -> R) rethrows -> R {
        var cParams = synap_engine_params_default()
        cParams.n_ctx = nCtx
        cParams.n_batch = nBatch
        cParams.n_threads = nThreads
        cParams.n_gpu_layers = nGPULayers
        cParams.kv_type_k = kvTypeK.rawValue
        cParams.kv_type_v = kvTypeV.rawValue
        cParams.flash_attn = flashAttention.rawValue
        cParams.mmproj_use_gpu = mmprojUseGPU
        cParams.warmup = warmup
        cParams.temp = temperature
        cParams.top_p = topP
        cParams.top_k = topK
        cParams.repeat_penalty = repeatPenalty
        cParams.repeat_last_n = repeatLastN
        cParams.seed = seed

        return try modelPath.withCString { modelCStr in
            cParams.model_path = modelCStr
            if let mmprojPath {
                return try mmprojPath.withCString { mmprojCStr in
                    cParams.mmproj_path = mmprojCStr
                    return try body(cParams)
                }
            }
            return try body(cParams)
        }
    }
}

/// Telemetry from the most recent generate call.
struct GenerationStats: Sendable {
    var promptTokens: Int32 = 0
    var prefillReused: Int32 = 0
    var prefillNew: Int32 = 0
    var prefillMs: Double = 0
    var decodeTokens: Int32 = 0
    var decodeMs: Double = 0

    var decodeTokensPerSecond: Double {
        decodeMs > 0 ? Double(decodeTokens) / (decodeMs / 1000) : 0
    }
    var prefillTokensPerSecond: Double {
        prefillMs > 0 ? Double(prefillNew) / (prefillMs / 1000) : 0
    }

    init() {}

    init(c: SynapGenStats) {
        promptTokens = c.prompt_tokens
        prefillReused = c.prefill_reused
        prefillNew = c.prefill_new
        prefillMs = c.prefill_ms
        decodeTokens = c.decode_tokens
        decodeMs = c.decode_ms
    }
}
