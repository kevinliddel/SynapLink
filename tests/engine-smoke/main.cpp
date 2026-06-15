//
//  main.cpp — desktop smoke test for synap_engine
//
//  Links the macOS slice of llama.xcframework and exercises the same C API
//  the iOS app uses: load, chat-template, two streamed generations (the
//  second must hit KV prefix reuse), cancel-after-N-pieces, stats, free.
//
//  Usage: engine-smoke <model.gguf> [mmproj.gguf] [image.jpg] [audio.wav]
//  With mmproj + media files it also runs multimodal turns through the
//  mtmd path (image and/or audio prefill → streamed reply).
//  Exit codes: 0 ok, 1 usage, 2 load failed, 3 generate failed,
//              4 reuse failed, 5 media turn failed
//

#include "synap_engine.h"

#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
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

void print_stats(const SynapEngine* engine, const char* label);

std::vector<uint8_t> read_file(const char* path) {
    std::ifstream in(path, std::ios::binary);
    return std::vector<uint8_t>(std::istreambuf_iterator<char>(in), {});
}

/// One media turn: marker-bearing templated prompt + raw file bytes.
/// Returns 0 on success, 5 on failure.
int media_turn(SynapEngine* engine, const char* label, const char* path, const char* question) {
    printf("\n== %s ==\n", label);
    const std::vector<uint8_t> bytes = read_file(path);
    if (bytes.empty()) {
        fprintf(stderr, "FAIL: cannot read %s\n", path);
        return 5;
    }
    const std::string user = std::string(synap_engine_media_marker()) + question;
    std::string prompt     = templated_prompt(engine, {
                                                          {"user", user.c_str()},
                                                      });
    if (prompt.empty()) {
        fprintf(stderr, "FAIL: template for media turn\n");
        return 5;
    }
    SynapMediaInput media = {bytes.data(), bytes.size()};
    SinkState sink;
    const int32_t rc = synap_engine_generate(engine, prompt.c_str(), &media, 1, 64, on_piece, &sink);
    if (rc != 0 || sink.text.empty()) {
        fprintf(stderr, "FAIL: %s rc=%d pieces=%d\n", label, rc, sink.pieces);
        return 5;
    }
    print_stats(engine, label);
    return 0;
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
    // Line-buffer stdout so crash output isn't lost when redirected to a file.
    setvbuf(stdout, nullptr, _IOLBF, 0);

    if (argc < 2) {
        fprintf(stderr, "usage: %s <model.gguf> [mmproj.gguf] [image] [audio]\n", argv[0]);
        return 1;
    }

    SynapEngineParams params = synap_engine_params_default();
    params.model_path        = argv[1];
    params.mmproj_path       = argc > 2 ? argv[2] : nullptr;
    params.seed              = 42; // deterministic-ish for a smoke test
#if defined(__x86_64__)
    // ggml's Metal kernels require an Apple-family GPU; on Intel Macs run CPU-only.
    params.n_gpu_layers   = 0;
    params.mmproj_use_gpu = false;
#endif
    // CI escape hatch for runners without a usable Metal device.
    const char* force_cpu = std::getenv("SYNAP_SMOKE_CPU");
    if (force_cpu && force_cpu[0] == '1') {
        params.n_gpu_layers   = 0;
        params.mmproj_use_gpu = false;
    }

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

    // Media turns (engine must have an mmproj loaded; files are optional args)
    if (argc > 3 && synap_engine_has_vision(engine)) {
        const int rc4 = media_turn(engine, "turn 4 (image)", argv[3], "Describe this image in one short sentence.");
        if (rc4 != 0) {
            synap_engine_free(engine);
            return rc4;
        }
    }
    if (argc > 4 && synap_engine_has_audio(engine)) {
        const int rc5 =
            media_turn(engine, "turn 5 (audio)", argv[4], "What do you hear in this audio clip? Answer briefly.");
        if (rc5 != 0) {
            synap_engine_free(engine);
            return rc5;
        }
    }

    synap_engine_clear_kv(engine);
    synap_engine_free(engine);
    printf("\nOK: all engine smoke checks passed\n");
    return 0;
}
