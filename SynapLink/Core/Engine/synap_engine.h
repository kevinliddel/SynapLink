//
//  synap_engine.h
//  SynapLink
//
//  Pure-C public API for the multimodal inference core (llama.cpp + libmtmd).
//  Swift imports this via the bridging header; C++ symbols stay hidden.
//
//  Threading contract: one engine = one serialized owner. `synap_engine_generate`
//  blocks the calling thread; only `synap_engine_cancel` may be called
//  concurrently from another thread.
//

#pragma once

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Opaque inference engine. Swift holds this as `OpaquePointer`.
typedef struct SynapEngine SynapEngine;

/// Called once per emitted UTF-8 text piece (null-terminated, always a
/// complete UTF-8 sequence). Return `false` to stop generation.
typedef bool (*SynapTokenCallback)(const char* piece, void* user_data);

// MARK: - Creation parameters

typedef struct SynapEngineParams {
    const char* model_path;   // GGUF text model — required
    const char* mmproj_path;  // GGUF multimodal projector — NULL for text-only

    int32_t n_ctx;            // context window (tokens)
    int32_t n_batch;          // logical batch size for prefill
    int32_t n_threads;        // CPU threads (decode + batch)
    int32_t n_gpu_layers;     // 999 = offload everything to Metal, 0 = CPU only

    // KV cache quantization: raw ggml_type values (1 = F16, 8 = q8_0, 2 = q4_0).
    // Quantized KV requires flash attention enabled.
    int32_t kv_type_k;
    int32_t kv_type_v;
    int32_t flash_attn;       // -1 auto, 0 disabled, 1 enabled

    bool mmproj_use_gpu;      // run the media encoder on Metal
    bool warmup;              // run a warmup encode/decode pass at load (costs time + peak memory)

    // Sampler chain: penalties -> top_k -> top_p -> temp -> dist
    float    temp;
    float    top_p;
    int32_t  top_k;
    float    repeat_penalty;
    int32_t  repeat_last_n;
    uint32_t seed;            // sampling seed (0 = nondeterministic default)
} SynapEngineParams;

/// Defaults tuned for the iPhone 11 baseline: ctx 2048, q8_0 KV + flash
/// attention, full Metal offload, no warmup.
SynapEngineParams synap_engine_params_default(void);

// MARK: - Lifecycle

/// Create an engine from a GGUF model (and optional mmproj). Returns NULL on
/// any failure (file missing, OOM, mmproj/model mismatch).
SynapEngine* synap_engine_create(const SynapEngineParams* params);

/// Destroy the engine and release all memory (model, contexts, KV cache).
void synap_engine_free(SynapEngine* engine);

// MARK: - Capabilities

bool    synap_engine_has_vision(const SynapEngine* engine);
bool    synap_engine_has_audio(const SynapEngine* engine);
/// Required input sample rate in Hz for raw audio, or -1 if unsupported.
int32_t synap_engine_audio_sample_rate(const SynapEngine* engine);
int32_t synap_engine_n_ctx(const SynapEngine* engine);

/// The marker string that must appear in the prompt once per media input
/// (e.g. "<__media__>"). Static storage — do not free.
const char* synap_engine_media_marker(void);

/// Short human-readable model description ("gemma4 E2B Q4_K_M ..."), written
/// into `out_buf`. Returns bytes written or negative on error.
int32_t synap_engine_model_desc(const SynapEngine* engine, char* out_buf, int32_t out_buf_size);

/// llama.cpp system/build info string (static storage).
const char* synap_engine_system_info(void);

// MARK: - Chat template

/// Apply the model's built-in chat template. Returns bytes written (excluding
/// null terminator), or negative on error. If the return value is
/// >= out_buf_size the buffer was too small — call again with a bigger one.
int32_t synap_engine_apply_chat_template(
    const SynapEngine* engine,
    const char* const* roles,
    const char* const* contents,
    int32_t            n_messages,
    bool               add_generation_prompt,
    char*              out_buf,
    int32_t            out_buf_size
);

// MARK: - Generation

/// One media input (image or audio), as the raw bytes of an encoded file.
/// Images: jpg/png/bmp/gif (decoded by stb_image). Audio: wav/mp3/flac
/// (decoded by miniaudio); format is auto-detected from magic bytes.
typedef struct SynapMediaInput {
    const uint8_t* data;
    size_t         len;
} SynapMediaInput;

/// Generate a streamed response for `prompt`. Blocks until done or cancelled.
///
/// `prompt` is the full templated conversation text. It must contain exactly
/// `n_media` occurrences of the media marker (see synap_engine_media_marker);
/// pass n_media = 0 for text-only turns.
///
/// Text-only turns reuse the KV cache via longest-common-prefix matching, so
/// multi-turn chats only prefill the new suffix. Turns with media re-evaluate
/// from scratch (KV reuse across media turns lands in Phase 2).
///
/// Returns 0 on success (including cancel/stop), negative on error:
///   -1 invalid arguments        -2 tokenization failed
///   -3 prefill/eval failed      -4 media decode failed
int32_t synap_engine_generate(
    SynapEngine*           engine,
    const char*            prompt,
    const SynapMediaInput* media,
    int32_t                n_media,
    int32_t                max_new_tokens,
    SynapTokenCallback     on_token,
    void*                  user_data
);

/// Signal the running generation to stop cleanly after the current token.
/// Thread-safe — may be called from any thread.
void synap_engine_cancel(SynapEngine* engine);

/// Drop the entire KV cache (memory-pressure escape hatch). The next
/// generate call re-prefills from scratch. Must not run concurrently with
/// `synap_engine_generate`.
void synap_engine_clear_kv(SynapEngine* engine);

// MARK: - Telemetry (last generate call)

typedef struct SynapGenStats {
    int32_t prompt_tokens;    // total prompt tokens this turn (text path only; 0 on media turns)
    int32_t prefill_reused;   // prompt tokens served by KV prefix reuse
    int32_t prefill_new;      // prompt tokens actually decoded (or media-eval token count)
    double  prefill_ms;       // wall time of prefill / media eval
    int32_t decode_tokens;    // tokens generated
    double  decode_ms;        // wall time of the decode loop
} SynapGenStats;

/// Read telemetry from the most recent generate call. Safe to call after
/// generation completes. Pass NULL for fields you don't want — `stats` itself
/// must be non-NULL.
void synap_engine_get_stats(const SynapEngine* engine, SynapGenStats* stats);

#ifdef __cplusplus
}
#endif
