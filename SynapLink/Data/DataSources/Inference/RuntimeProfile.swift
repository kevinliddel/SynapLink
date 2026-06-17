//
//  RuntimeProfile.swift
//  SynapLink
//
//  Device-tier engine tuning — the single place that decides context size,
//  threads and KV quantization per RAM class. The 4 GB tier keeps 2 threads
//  (more spills onto E-cores and hurts decode) and q4_0 KV — NeuraLink's A13
//  device-sweep results. The old ctx-1024 cap was specifically to survive
//  Gemma 4 E2B's KV on the iPhone 11; E2B is now RAM-gated to ≥6 GB, so the
//  4 GB tier only runs the small Gemma 3 1B, whose q4_0 KV at 2048 ctx is well
//  under ~100 MB — trivial here. Raised to 2048 so a reply plus the prior turn
//  fit in context (at ctx 1024 a single long answer trimmed out the whole
//  prior exchange, and follow-ups lost the conversation).
//

import Foundation
import Metal

enum RuntimeProfile {

    static var physicalMemoryGB: Double {
        Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824.0
    }

    /// Engine parameters tuned for this device, for the given model files.
    static func engineParams(modelPath: String, mmprojPath: String?) -> EngineParams {
        var params = EngineParams(modelPath: modelPath)
        params.mmprojPath = mmprojPath

        let gb = physicalMemoryGB
        switch gb {
        case ..<5.0:
            // iPhone 11/12/13 class — runs the small Gemma 3 1B (E2B is gated
            // to ≥6 GB). 2048 ctx fits a reply + the prior turn for follow-ups;
            // its q4_0 KV is tiny for a 1B model, so memory stays well in budget.
            params.nCtx = 2048
            params.nThreads = 2
            params.kvTypeK = .q4_0
            params.kvTypeV = .q4_0
        case ..<7.0:
            params.nCtx = 2048
            params.nThreads = 4
            params.kvTypeK = .q8_0
            params.kvTypeV = .q8_0
        default:
            params.nCtx = 4096
            params.nThreads = 4
            params.kvTypeK = .q8_0
            params.kvTypeV = .q8_0
        }

        // Never exceed physical cores (SMT overcommit hurts throughput).
        params.nThreads = min(params.nThreads, Int32(ProcessInfo.processInfo.processorCount))
        return params
    }

    // MARK: - Specialists (whisper ASR, SmolVLM vision)

    /// Specialists run while the main chat model is also resident. On the
    /// simulator the GPU path is emulated/absent (and CLIP-on-Metal crashes
    /// on non-Apple GPUs); device specialists use Metal.
    static var specialistUsesGPU: Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        return true
        #endif
    }

    static var specialistThreads: Int32 {
        Int32(min(2, ProcessInfo.processInfo.processorCount))
    }

    /// True when the default Metal GPU implements simdgroup matrix-multiply
    /// (Apple7 / A14 / M1 and later). GPUs before that (e.g. the A13's Apple6)
    /// make ggml-Metal fall back to kernels that miscompute — proven for us by
    /// whisper's encoder there (garbage features → language auto-detect at
    /// p≈0.27 → zero segments → empty transcript on iPhone 11).
    private static let metalHasSimdgroupMatrix: Bool = {
        guard let device = MTLCreateSystemDefaultDevice() else { return false }
        return device.supportsFamily(.apple7)
    }()

    /// whisper.cpp on Metal needs simdgroup matrix-multiply for a correct
    /// encoder; without it the transcript comes back empty. Run whisper on CPU
    /// on those GPUs — it's a 147 MB base model and the CPU path transcribes a
    /// few seconds of audio in ~1–2 s (the proven-correct desktop path).
    static var whisperUsesGPU: Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        return metalHasSimdgroupMatrix
        #endif
    }

    /// Image-generation (stable-diffusion.cpp) tunables per RAM tier. The
    /// 4 GB tier is deliberately experimental: small canvas keeps the
    /// diffusion working set under the jetsam ceiling, and EULER_A at a modest
    /// step count is the quality/speed compromise on the A13. Bigger devices
    /// get a full 512² canvas.
    static var imageGenSettings: ImageGenSettings {
        let eulerAncestral: Int32 = 1
        switch physicalMemoryGB {
        case ..<5.0:
            // iPhone 11 tier: small canvas keeps the CPU diffusion working set
            // modest. Diffusion time is ~linear in steps and each step is ~15 s
            // on the A13's 2 usable cores, so 8 steps (a fast Euler-A preview)
            // keeps it near ~2 min instead of ~4. Quality is rough — this tier
            // is experimental; raise steps for fidelity if a device can wait.
            return ImageGenSettings(width: 256, height: 256, steps: 8,
                                    cfgScale: 7.0, sampleMethod: eulerAncestral)
        case ..<7.0:
            return ImageGenSettings(width: 512, height: 512, steps: 20,
                                    cfgScale: 7.0, sampleMethod: eulerAncestral)
        default:
            return ImageGenSettings(width: 512, height: 512, steps: 28,
                                    cfgScale: 7.5, sampleMethod: eulerAncestral)
        }
    }

    /// Image generation runs on CPU on the 4 GB tier. ggml-Metal on the A13
    /// exceeds the GPU's working-set limit loading SD 1.5 (~1.6 GB) and
    /// aborts; CPU can use the full jetsam budget and is proven to work
    /// (slower). ≥6 GB devices have the Metal headroom to use the GPU.
    static var imageGenUsesGPU: Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        return physicalMemoryGB >= 6.0
        #endif
    }

    /// Vision specialist (SmolVLM) engine params: small context — it captions
    /// one image per call, no long history.
    static func visionEngineParams(modelPath: String, mmprojPath: String?) -> EngineParams {
        var params = EngineParams(modelPath: modelPath)
        params.mmprojPath = mmprojPath
        params.nCtx = 1024
        params.nThreads = specialistThreads
        params.kvTypeK = .f16
        params.kvTypeV = .f16
        params.flashAttention = .disabled  // tiny model; avoids the quant-KV+FA coupling
        #if targetEnvironment(simulator)
        params.nGPULayers = 0
        params.mmprojUseGPU = false
        #endif
        return params
    }
}
