//
//  synap_engine_internal.hpp
//  SynapLink
//
//  Internal state shared by the synap_engine implementation. Not exposed to
//  Swift — only synap_engine.h crosses the bridging header.
//

#pragma once

#include <llama/llama.h>
#include <llama/mtmd.h>

#include <atomic>
#include <string>
#include <vector>

struct SynapEngine {
    llama_model* model     = nullptr;
    llama_context* ctx     = nullptr;
    llama_sampler* sampler = nullptr;
    mtmd_context* mctx     = nullptr; // NULL when running text-only

    // Tokens currently materialised in the KV cache (text-only turns).
    // Used for longest-common-prefix reuse across turns.
    std::vector<llama_token> kv_tokens;

    // Set after a media turn: kv_tokens no longer describes the KV cache
    // (media chunks occupy positions), so the next text turn must clear.
    bool kv_has_media = false;

    std::atomic<bool> cancel_flag{false};

    // Telemetry for the most recent generate call.
    int32_t last_prompt_tokens  = 0;
    int32_t last_prefill_reused = 0;
    int32_t last_prefill_new    = 0;
    double last_prefill_ms      = 0.0;
    int32_t last_decode_tokens  = 0;
    double last_decode_ms       = 0.0;
};

/// Length of the longest prefix of `buf` that ends on a complete UTF-8
/// code-point boundary. Token pieces can split multi-byte characters
/// (CJK, emoji); we buffer the tail until the rest arrives. Malformed
/// sequences are passed through whole rather than held forever.
inline std::size_t utf8_safe_prefix(const std::string& buf) {
    const std::size_t n = buf.size();
    if (n == 0) { return 0; }

    // Walk back over trailing continuation bytes (10xxxxxx) to the lead byte.
    std::size_t i = n;
    while (i > 0 && (static_cast<unsigned char>(buf[i - 1]) & 0xC0) == 0x80) {
        --i;
        if (n - i >= 4) { return n; } // > 4 trailing continuations: malformed, flush all
    }
    if (i == 0) { return n; } // nothing but continuation bytes: malformed, flush all

    const unsigned char lead = static_cast<unsigned char>(buf[i - 1]);
    std::size_t expected;
    if ((lead & 0x80) == 0x00) {
        expected = 1;
    } else if ((lead & 0xE0) == 0xC0) {
        expected = 2;
    } else if ((lead & 0xF0) == 0xE0) {
        expected = 3;
    } else if ((lead & 0xF8) == 0xF0) {
        expected = 4;
    } else {
        return n;
    } // invalid lead byte: flush all

    const std::size_t have = n - (i - 1);
    return have >= expected ? n : i - 1;
}
