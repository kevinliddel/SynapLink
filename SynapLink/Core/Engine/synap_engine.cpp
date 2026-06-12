//
//  synap_engine.cpp
//  SynapLink
//
//  C++ implementation of the synap_engine public API. Integrates llama.cpp
//  via its public C API (llama.h) and multimodal input via libmtmd.
//
//  Section layout:
//    §1  Lifecycle (params / create / free)
//    §2  Capabilities & chat template
//    §3  Tokenization + KV prefix-reuse prefill (text path)
//    §4  Media prefill (mtmd tokenize + eval)
//    §5  Decode loop + UTF-8 safe emission
//    §6  Public generate dispatcher, cancel, telemetry
//

#include "synap_engine.h"
#include "synap_engine_internal.hpp"

#include <llama/mtmd-helper.h>

#include <algorithm>
#include <chrono>
#include <cstring>

// MARK: - §1 Lifecycle

SynapEngineParams synap_engine_params_default(void) {
    SynapEngineParams p = {};
    p.model_path        = nullptr;
    p.mmproj_path       = nullptr;
    p.n_ctx             = 2048;
    p.n_batch           = 512;
    p.n_threads         = 4;
    p.n_gpu_layers      = 999;
    p.kv_type_k         = 8; // GGML_TYPE_Q8_0
    p.kv_type_v         = 8; // GGML_TYPE_Q8_0
    p.flash_attn        = 1; // quantized KV requires flash attention
    p.mmproj_use_gpu    = true;
    p.warmup            = false;
    p.temp              = 0.7f;
    p.top_p             = 0.9f;
    p.top_k             = 40;
    p.repeat_penalty    = 1.1f;
    p.repeat_last_n     = 64;
    p.seed              = 0;
    return p;
}

static llama_sampler* build_sampler(const SynapEngineParams& p) {
    auto sparams         = llama_sampler_chain_default_params();
    llama_sampler* chain = llama_sampler_chain_init(sparams);
    if (!chain) { return nullptr; }

    llama_sampler_chain_add(
        chain, llama_sampler_init_penalties(p.repeat_last_n, p.repeat_penalty, /*freq=*/0.0f, /*present=*/0.0f));
    llama_sampler_chain_add(chain, llama_sampler_init_top_k(p.top_k));
    llama_sampler_chain_add(chain, llama_sampler_init_top_p(p.top_p, 1));
    llama_sampler_chain_add(chain, llama_sampler_init_temp(p.temp));
    llama_sampler_chain_add(chain, llama_sampler_init_dist(p.seed));
    return chain;
}

SynapEngine* synap_engine_create(const SynapEngineParams* params) {
    if (!params || !params->model_path) { return nullptr; }

    llama_backend_init();

    llama_model_params mp = llama_model_default_params();
    mp.n_gpu_layers       = params->n_gpu_layers;

    llama_model* model = llama_model_load_from_file(params->model_path, mp);
    if (!model) {
        llama_backend_free();
        return nullptr;
    }

    llama_context_params cp = llama_context_default_params();
    cp.n_ctx                = static_cast<uint32_t>(params->n_ctx);
    cp.n_batch              = static_cast<uint32_t>(params->n_batch);
    cp.n_threads            = params->n_threads;
    cp.n_threads_batch      = params->n_threads;
    cp.type_k               = static_cast<enum ggml_type>(params->kv_type_k);
    cp.type_v               = static_cast<enum ggml_type>(params->kv_type_v);
    cp.flash_attn_type      = static_cast<enum llama_flash_attn_type>(params->flash_attn);

    llama_context* ctx = llama_init_from_model(model, cp);
    if (!ctx) {
        llama_model_free(model);
        llama_backend_free();
        return nullptr;
    }

    llama_sampler* sampler = build_sampler(*params);
    if (!sampler) {
        llama_free(ctx);
        llama_model_free(model);
        llama_backend_free();
        return nullptr;
    }

    mtmd_context* mctx = nullptr;
    if (params->mmproj_path && params->mmproj_path[0] != '\0') {
        mtmd_context_params mparams = mtmd_context_params_default();
        mparams.use_gpu             = params->mmproj_use_gpu;
        mparams.n_threads           = params->n_threads;
        mparams.flash_attn_type     = static_cast<enum llama_flash_attn_type>(params->flash_attn);
        mparams.warmup              = params->warmup;
        mparams.print_timings       = false;

        mctx = mtmd_init_from_file(params->mmproj_path, model, mparams);
        if (!mctx) {
            llama_sampler_free(sampler);
            llama_free(ctx);
            llama_model_free(model);
            llama_backend_free();
            return nullptr;
        }
    }

    auto* engine    = new SynapEngine();
    engine->model   = model;
    engine->ctx     = ctx;
    engine->sampler = sampler;
    engine->mctx    = mctx;
    return engine;
}

void synap_engine_free(SynapEngine* engine) {
    if (!engine) { return; }
    if (engine->mctx) { mtmd_free(engine->mctx); }
    if (engine->sampler) { llama_sampler_free(engine->sampler); }
    if (engine->ctx) { llama_free(engine->ctx); }
    if (engine->model) { llama_model_free(engine->model); }
    llama_backend_free();
    delete engine;
}

// MARK: - §2 Capabilities & chat template

bool synap_engine_has_vision(const SynapEngine* engine) {
    return engine && engine->mctx && mtmd_support_vision(engine->mctx);
}

bool synap_engine_has_audio(const SynapEngine* engine) {
    return engine && engine->mctx && mtmd_support_audio(engine->mctx);
}

int32_t synap_engine_audio_sample_rate(const SynapEngine* engine) {
    if (!engine || !engine->mctx) { return -1; }
    return mtmd_get_audio_sample_rate(engine->mctx);
}

int32_t synap_engine_n_ctx(const SynapEngine* engine) {
    return engine && engine->ctx ? static_cast<int32_t>(llama_n_ctx(engine->ctx)) : 0;
}

const char* synap_engine_media_marker(void) {
    return mtmd_default_marker();
}

int32_t synap_engine_model_desc(const SynapEngine* engine, char* out_buf, int32_t out_buf_size) {
    if (!engine || !engine->model || !out_buf || out_buf_size <= 0) { return -1; }
    return llama_model_desc(engine->model, out_buf, static_cast<size_t>(out_buf_size));
}

const char* synap_engine_system_info(void) {
    return llama_print_system_info();
}

static std::string trim_copy(const char* text) {
    std::string s    = text ? text : "";
    const auto begin = s.find_first_not_of(" \t\n\r");
    if (begin == std::string::npos) { return ""; }
    const auto end = s.find_last_not_of(" \t\n\r");
    return s.substr(begin, end - begin + 1);
}

/// Gemma 4 turn format: "<|turn>{role}\n{content}<turn|>\n", assistant role
/// rendered as "model", generation prompt = trailing "<|turn>model\n".
/// llama.cpp b9596's built-in template detector predates this marker, so
/// llama_chat_apply_template returns -1 for Gemma 4 GGUFs; this fallback
/// covers the plain-chat path (tools/thinking channels are out of scope).
/// BOS is NOT emitted — tokenization with add_special=true adds it, matching
/// the behavior of llama.cpp's built-in formatters.
static int32_t apply_gemma4_template(const char* const* roles, const char* const* contents, int32_t n_messages,
                                     bool add_generation_prompt, char* out_buf, int32_t out_buf_size) {
    std::string ss;
    int32_t first = 0;
    if (strcmp(roles[0], "system") == 0 || strcmp(roles[0], "developer") == 0) {
        ss += "<|turn>system\n";
        ss += trim_copy(contents[0]);
        ss += "<turn|>\n";
        first = 1;
    }
    for (int32_t i = first; i < n_messages; ++i) {
        std::string role = roles[i];
        if (role == "assistant") { role = "model"; }
        ss += "<|turn>" + role + "\n";
        ss += trim_copy(contents[i]);
        ss += "<turn|>\n";
    }
    if (add_generation_prompt) { ss += "<|turn>model\n"; }

    // Same contract as llama_chat_apply_template: return the total length,
    // copy what fits — callers retry with a bigger buffer when total >= size.
    const int32_t total = static_cast<int32_t>(ss.size());
    const int32_t n     = std::min(total, out_buf_size);
    memcpy(out_buf, ss.data(), static_cast<size_t>(n));
    return total;
}

int32_t synap_engine_apply_chat_template(const SynapEngine* engine, const char* const* roles,
                                         const char* const* contents, int32_t n_messages, bool add_generation_prompt,
                                         char* out_buf, int32_t out_buf_size) {
    if (!engine || !engine->model || !roles || !contents || n_messages <= 0 || !out_buf || out_buf_size <= 0) {
        return -1;
    }
    const char* tmpl = llama_model_chat_template(engine->model, nullptr);

    std::vector<llama_chat_message> messages;
    messages.reserve(static_cast<size_t>(n_messages));
    for (int32_t i = 0; i < n_messages; ++i) { messages.push_back({roles[i], contents[i]}); }
    const int32_t rc =
        llama_chat_apply_template(tmpl, messages.data(), messages.size(), add_generation_prompt, out_buf, out_buf_size);
    if (rc < 0 && tmpl && strstr(tmpl, "<|turn>") != nullptr) {
        return apply_gemma4_template(roles, contents, n_messages, add_generation_prompt, out_buf, out_buf_size);
    }
    return rc;
}

// MARK: - §3 Text path: tokenization + KV prefix-reuse prefill

static bool tokenise_into(llama_model* model, const char* prompt, std::vector<llama_token>& out) {
    const auto* vocab = llama_model_get_vocab(model);
    out.resize(2048);
    int n = llama_tokenize(vocab, prompt, static_cast<int32_t>(strlen(prompt)), out.data(),
                           static_cast<int32_t>(out.size()),
                           /*add_special=*/true, /*parse_special=*/true);
    if (n < 0) {
        out.resize(static_cast<size_t>(-n));
        n = llama_tokenize(vocab, prompt, static_cast<int32_t>(strlen(prompt)), out.data(),
                           static_cast<int32_t>(out.size()), true, true);
    }
    if (n <= 0) { return false; }
    out.resize(static_cast<size_t>(n));
    return true;
}

static size_t common_prefix_len(const std::vector<llama_token>& a, const std::vector<llama_token>& b) {
    const size_t n = std::min(a.size(), b.size());
    size_t i       = 0;
    while (i < n && a[i] == b[i]) { ++i; }
    return i;
}

/// Sync the KV cache to `new_tokens` via longest-common-prefix reuse and
/// decode only the suffix. Leaves the last token's logits ready for sampling.
/// On failure both caches are wiped so the engine stays in a clean state.
static bool prefill_text(SynapEngine* h, const std::vector<llama_token>& new_tokens) {
    if (new_tokens.empty()) { return false; }

    auto* memory = llama_get_memory(h->ctx);

    // A previous media turn left positions kv_tokens doesn't describe.
    if (h->kv_has_media) {
        llama_memory_clear(memory, true);
        h->kv_tokens.clear();
        h->kv_has_media = false;
    }

    size_t common = common_prefix_len(h->kv_tokens, new_tokens);
    // Always re-decode at least the final token so its logits are available.
    if (common >= new_tokens.size()) { common = new_tokens.size() - 1; }

    if (h->kv_tokens.empty() || common == 0) {
        llama_memory_clear(memory, true);
        common = 0;
    } else if (common < h->kv_tokens.size()) {
        llama_memory_seq_rm(memory, 0, static_cast<llama_pos>(common), -1);
    }

    const size_t suffix_len = new_tokens.size() - common;
    const auto t0           = std::chrono::steady_clock::now();
    if (suffix_len > 0) {
        llama_batch batch =
            llama_batch_get_one(const_cast<llama_token*>(new_tokens.data() + common), static_cast<int32_t>(suffix_len));
        if (llama_decode(h->ctx, batch) != 0) {
            llama_memory_clear(memory, true);
            h->kv_tokens.clear();
            return false;
        }
    }
    const auto t1 = std::chrono::steady_clock::now();

    h->last_prefill_reused = static_cast<int32_t>(common);
    h->last_prefill_new    = static_cast<int32_t>(suffix_len);
    h->last_prefill_ms     = std::chrono::duration<double, std::milli>(t1 - t0).count();
    h->kv_tokens           = new_tokens;
    return true;
}

// MARK: - §4 Media path: mtmd tokenize + eval

/// Decode media buffers, tokenize prompt + media into chunks, and evaluate
/// everything from a cleared KV cache. Returns 0 or a synap_engine_generate
/// error code.
static int32_t prefill_media(SynapEngine* h, const char* prompt, const SynapMediaInput* media, int32_t n_media) {
    std::vector<mtmd_bitmap*> bitmaps;
    bitmaps.reserve(static_cast<size_t>(n_media));

    auto free_bitmaps = [&bitmaps]() {
        for (auto* b : bitmaps) { mtmd_bitmap_free(b); }
        bitmaps.clear();
    };

    for (int32_t i = 0; i < n_media; ++i) {
        if (!media[i].data || media[i].len == 0) {
            free_bitmaps();
            return -4;
        }
        mtmd_helper_bitmap_wrapper w =
            mtmd_helper_bitmap_init_from_buf(h->mctx, media[i].data, media[i].len, /*placeholder=*/false);
        if (w.video_ctx) {
            // Video is compiled out (MTMD_VIDEO=OFF); refuse rather than leak.
            mtmd_helper_video_free(w.video_ctx);
            if (w.bitmap) { mtmd_bitmap_free(w.bitmap); }
            free_bitmaps();
            return -4;
        }
        if (!w.bitmap) {
            free_bitmaps();
            return -4;
        }
        bitmaps.push_back(w.bitmap);
    }

    mtmd_input_text text = {};
    text.text            = prompt;
    text.add_special     = true;
    text.parse_special   = true;

    mtmd_input_chunks* chunks = mtmd_input_chunks_init();
    const int32_t tok_rc =
        mtmd_tokenize(h->mctx, chunks, &text, const_cast<const mtmd_bitmap**>(bitmaps.data()), bitmaps.size());
    free_bitmaps();
    if (tok_rc != 0) {
        mtmd_input_chunks_free(chunks);
        return -2;
    }

    auto* memory = llama_get_memory(h->ctx);
    llama_memory_clear(memory, true);
    h->kv_tokens.clear();
    h->kv_has_media = true;

    const auto t0    = std::chrono::steady_clock::now();
    llama_pos n_past = 0;
    const int32_t eval_rc =
        mtmd_helper_eval_chunks(h->mctx, h->ctx, chunks,
                                /*n_past=*/0, /*seq_id=*/0, static_cast<int32_t>(llama_n_batch(h->ctx)),
                                /*logits_last=*/true, &n_past);
    const auto t1 = std::chrono::steady_clock::now();

    const size_t n_tokens = mtmd_helper_get_n_tokens(chunks);
    mtmd_input_chunks_free(chunks);

    if (eval_rc != 0) {
        llama_memory_clear(memory, true);
        h->kv_has_media = false;
        return -3;
    }

    h->last_prefill_reused = 0;
    h->last_prefill_new    = static_cast<int32_t>(n_tokens);
    h->last_prefill_ms     = std::chrono::duration<double, std::milli>(t1 - t0).count();
    return 0;
}

// MARK: - §5 Decode loop

static bool emit_utf8_safe(std::string& buf, const char* piece, int piece_len, SynapTokenCallback on_token,
                           void* user_data) {
    if (piece_len > 0) { buf.append(piece, static_cast<size_t>(piece_len)); }
    const std::size_t safe = utf8_safe_prefix(buf);
    if (safe == 0) { return true; }
    const std::string prefix = buf.substr(0, safe);
    buf.erase(0, safe);
    return on_token ? on_token(prefix.c_str(), user_data) : true;
}

/// Forward whatever bytes remain after the loop exits. Malformed trailing
/// fragments still reach Swift — better mojibake than silently dropped output.
static void flush_utf8_remaining(std::string& buf, SynapTokenCallback on_token, void* user_data) {
    if (buf.empty() || !on_token) {
        buf.clear();
        return;
    }
    on_token(buf.c_str(), user_data);
    buf.clear();
}

/// Sample → emit → decode loop. `track_tokens` keeps kv_tokens in sync for
/// prefix reuse (text path only; meaningless after a media prefill).
static void decode_loop(SynapEngine* h, int32_t max_new_tokens, bool track_tokens, SynapTokenCallback on_token,
                        void* user_data) {
    const auto* vocab   = llama_model_get_vocab(h->model);
    char piece_buf[512] = {};
    std::string utf8_buf;
    int32_t generated = 0;

    const auto t0 = std::chrono::steady_clock::now();
    for (int32_t step = 0; step < max_new_tokens; ++step) {
        if (h->cancel_flag.load()) { break; }

        llama_token next = llama_sampler_sample(h->sampler, h->ctx, -1);
        llama_sampler_accept(h->sampler, next);

        if (llama_vocab_is_eog(vocab, next)) { break; }

        const int piece_len = llama_token_to_piece(vocab, next, piece_buf, sizeof(piece_buf), 0, true);
        ++generated;
        if (track_tokens) { h->kv_tokens.push_back(next); }
        if (piece_len > 0 && !emit_utf8_safe(utf8_buf, piece_buf, piece_len, on_token, user_data)) { break; }

        llama_batch nb = llama_batch_get_one(&next, 1);
        if (llama_decode(h->ctx, nb) != 0) { break; }
    }
    const auto t1 = std::chrono::steady_clock::now();

    flush_utf8_remaining(utf8_buf, on_token, user_data);
    h->last_decode_tokens = generated;
    h->last_decode_ms     = std::chrono::duration<double, std::milli>(t1 - t0).count();
}

// MARK: - §6 Public dispatcher

int32_t synap_engine_generate(SynapEngine* engine, const char* prompt, const SynapMediaInput* media, int32_t n_media,
                              int32_t max_new_tokens, SynapTokenCallback on_token, void* user_data) {
    if (!engine || !engine->model || !engine->ctx || !engine->sampler || !prompt || max_new_tokens <= 0 ||
        (n_media > 0 && !media)) {
        return -1;
    }
    if (n_media > 0 && !engine->mctx) {
        return -1; // media passed to a text-only engine
    }
    engine->cancel_flag.store(false);
    engine->last_prompt_tokens  = 0;
    engine->last_prefill_reused = 0;
    engine->last_prefill_new    = 0;
    engine->last_prefill_ms     = 0.0;
    engine->last_decode_tokens  = 0;
    engine->last_decode_ms      = 0.0;

    bool track_tokens = false;
    if (n_media > 0) {
        const int32_t rc = prefill_media(engine, prompt, media, n_media);
        if (rc != 0) { return rc; }
    } else {
        std::vector<llama_token> new_tokens;
        if (!tokenise_into(engine->model, prompt, new_tokens)) { return -2; }
        engine->last_prompt_tokens = static_cast<int32_t>(new_tokens.size());
        if (!prefill_text(engine, new_tokens)) { return -3; }
        track_tokens = true;
    }

    decode_loop(engine, max_new_tokens, track_tokens, on_token, user_data);
    return 0;
}

void synap_engine_cancel(SynapEngine* engine) {
    if (engine) { engine->cancel_flag.store(true); }
}

void synap_engine_clear_kv(SynapEngine* engine) {
    if (!engine || !engine->ctx) { return; }
    llama_memory_clear(llama_get_memory(engine->ctx), true);
    engine->kv_tokens.clear();
    engine->kv_has_media = false;
}

void synap_engine_get_stats(const SynapEngine* engine, SynapGenStats* stats) {
    if (!engine || !stats) { return; }
    stats->prompt_tokens  = engine->last_prompt_tokens;
    stats->prefill_reused = engine->last_prefill_reused;
    stats->prefill_new    = engine->last_prefill_new;
    stats->prefill_ms     = engine->last_prefill_ms;
    stats->decode_tokens  = engine->last_decode_tokens;
    stats->decode_ms      = engine->last_decode_ms;
}
