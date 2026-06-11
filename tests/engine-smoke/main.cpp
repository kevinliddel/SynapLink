//
//  main.cpp — desktop smoke test for synap_engine
//
//  Links the macOS slice of llama.xcframework and exercises the same C API
//  the iOS app uses: load, chat-template, two streamed generations (the
//  second must hit KV prefix reuse), cancel-after-N-pieces, stats, free.
//
//  Usage: engine-smoke <model.gguf> [mmproj.gguf]
//  Exit codes: 0 ok, 1 usage, 2 load failed, 3 generate failed, 4 reuse failed
//

#include "synap_engine.h"

#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

namespace {

struct SinkState {
    std::string text;
    int pieces     = 0;
    int stop_after = -1; // cancel test: return false after N pieces
};

bool on_piece(const char* piece, void* user) {
    auto* s = static_cast<SinkState*>(user);
    s->text += piece;
    s->pieces += 1;
    fputs(piece, stdout);
    fflush(stdout);
    return s->stop_after < 0 || s->pieces < s->stop_after;
}

std::string templated_prompt(const SynapEngine* engine, const std::vector<std::pair<const char*, const char*>>& msgs) {
    std::vector<const char*> roles, contents;
    for (const auto& m : msgs) {
        roles.push_back(m.first);
        contents.push_back(m.second);
    }
    std::vector<char> buf(16 * 1024);
    int32_t n =
        synap_engine_apply_chat_template(engine, roles.data(), contents.data(), static_cast<int32_t>(msgs.size()), true,
                                         buf.data(), static_cast<int32_t>(buf.size()));
    if (n <= 0) { return {}; }
    return std::string(buf.data(), static_cast<size_t>(n));
}

void print_stats(const SynapEngine* engine, const char* label) {
    SynapGenStats st = {};
    synap_engine_get_stats(engine, &st);
    const double decode_tps = st.decode_ms > 0 ? st.decode_tokens / (st.decode_ms / 1000.0) : 0;
    printf("\n[%s] prompt=%d reused=%d prefilled=%d (%.0f ms) | decoded=%d (%.0f ms, %.1f tok/s)\n", label,
           st.prompt_tokens, st.prefill_reused, st.prefill_new, st.prefill_ms, st.decode_tokens, st.decode_ms,
           decode_tps);
}

} // namespace

int main(int argc, char** argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: %s <model.gguf> [mmproj.gguf]\n", argv[0]);
        return 1;
    }

    SynapEngineParams params = synap_engine_params_default();
    params.model_path        = argv[1];
    params.mmproj_path       = argc > 2 ? argv[2] : nullptr;
    params.seed              = 42; // deterministic-ish for a smoke test
#if defined(__x86_64__)
    // ggml's Metal kernels require an Apple-family GPU; on Intel Macs run CPU-only.
    params.n_gpu_layers = 0;
#endif
    // CI escape hatch for runners without a usable Metal device.
    const char* force_cpu = std::getenv("SYNAP_SMOKE_CPU");
    if (force_cpu && force_cpu[0] == '1') { params.n_gpu_layers = 0; }

    printf("== load ==\n");
    SynapEngine* engine = synap_engine_create(&params);
    if (!engine) {
        fprintf(stderr, "FAIL: engine create\n");
        return 2;
    }
    char desc[256] = {};
    synap_engine_model_desc(engine, desc, sizeof(desc));
    printf("model: %s\nvision=%d audio=%d n_ctx=%d\n", desc, synap_engine_has_vision(engine),
           synap_engine_has_audio(engine), synap_engine_n_ctx(engine));

    // Turn 1
    printf("\n== turn 1 ==\n");
    std::string p1 = templated_prompt(engine, {
                                                  {"user", "Name three primary colors. Answer briefly."},
                                              });
    if (p1.empty()) {
        fprintf(stderr, "FAIL: chat template\n");
        synap_engine_free(engine);
        return 3;
    }

    SinkState s1;
    int32_t rc = synap_engine_generate(engine, p1.c_str(), nullptr, 0, 96, on_piece, &s1);
    if (rc != 0 || s1.text.empty()) {
        fprintf(stderr, "FAIL: turn 1 generate rc=%d pieces=%d\n", rc, s1.pieces);
        synap_engine_free(engine);
        return 3;
    }
    print_stats(engine, "turn 1");

    // Turn 2 — same history + follow-up; prefill_reused must be > 0
    printf("\n== turn 2 (KV prefix reuse) ==\n");
    std::string a1 = s1.text;
    std::string p2 = templated_prompt(engine, {
                                                  {"user", "Name three primary colors. Answer briefly."},
                                                  {"assistant", a1.c_str()},
                                                  {"user", "Which of those is the warmest?"},
                                              });
    SinkState s2;
    rc = synap_engine_generate(engine, p2.c_str(), nullptr, 0, 96, on_piece, &s2);
    if (rc != 0 || s2.text.empty()) {
        fprintf(stderr, "FAIL: turn 2 generate rc=%d\n", rc);
        synap_engine_free(engine);
        return 3;
    }
    SynapGenStats st2 = {};
    synap_engine_get_stats(engine, &st2);
    print_stats(engine, "turn 2");
    if (st2.prefill_reused <= 0) {
        fprintf(stderr, "FAIL: expected KV prefix reuse on turn 2 (reused=%d)\n", st2.prefill_reused);
        synap_engine_free(engine);
        return 4;
    }

    // Turn 3 — callback-driven stop after 5 pieces
    printf("\n== turn 3 (early stop via callback) ==\n");
    SinkState s3;
    s3.stop_after = 5;
    rc            = synap_engine_generate(engine, p1.c_str(), nullptr, 0, 96, on_piece, &s3);
    if (rc != 0) {
        fprintf(stderr, "FAIL: turn 3 rc=%d\n", rc);
        synap_engine_free(engine);
        return 3;
    }
    printf("\nstopped after %d pieces (asked for 5)\n", s3.pieces);

    synap_engine_clear_kv(engine);
    synap_engine_free(engine);
    printf("\nOK: all engine smoke checks passed\n");
    return 0;
}
