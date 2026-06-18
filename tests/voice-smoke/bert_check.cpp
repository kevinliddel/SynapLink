//
//  bert_check.cpp — desktop validation for synap_voice's ja_bert construction.
//
//  Runs the SHIPPING build_ja_bert (BERT session + word2ph repeat, via the
//  test-only synap_voice_debug_ja_bert hook) over the baked sentences and
//  compares to MeloTTS's own int8 ja_bert reference. A high cosine proves the
//  C++ ORT BERT run + the repeat/transpose into ja_bert[768, n] are correct.
//
//  Usage: bert-check <melo.onnx> <converter.onnx> <bert.onnx> <bert_check.bin> <ref_dir>
//

#include "synap_voice.h"

#include <cmath>
#include <cstdint>
#include <cstdio>
#include <fstream>
#include <string>
#include <vector>

namespace {

template <typename T>
bool read_n(std::ifstream& in, T* dst, size_t n) {
    return static_cast<bool>(in.read(reinterpret_cast<char*>(dst), static_cast<std::streamsize>(n * sizeof(T))));
}

double cosine(const std::vector<float>& a, const std::vector<float>& b) {
    const size_t n = std::min(a.size(), b.size());
    double dot = 0, na = 0, nb = 0;
    for (size_t i = 0; i < n; ++i) { dot += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i]; }
    return dot / (std::sqrt(na) * std::sqrt(nb) + 1e-9);
}

}  // namespace

int main(int argc, char** argv) {
    if (argc < 6) {
        fprintf(stderr, "usage: %s melo.onnx converter.onnx bert.onnx bert_check.bin ref_dir\n", argv[0]);
        return 1;
    }
    SynapVoice* v = synap_voice_create(argv[1], argv[2], argv[3]);
    if (!v) { fprintf(stderr, "synap_voice_create failed\n"); return 2; }

    std::ifstream in(argv[4], std::ios::binary);
    int32_t count = 0;
    if (!read_n(in, &count, 1)) { fprintf(stderr, "bad bert_check.bin\n"); return 3; }

    const std::string refDir = argv[5];
    bool allPass = true;
    for (int32_t i = 0; i < count; ++i) {
        int32_t n_ids = 0, n = 0;
        if (!read_n(in, &n_ids, 1) || !read_n(in, &n, 1)) { fprintf(stderr, "bad record %d\n", i); return 3; }
        std::vector<int64_t> ids(n_ids);
        std::vector<int32_t> w2p(n_ids);
        read_n(in, ids.data(), n_ids);
        read_n(in, w2p.data(), n_ids);

        std::vector<float> ja(static_cast<size_t>(768) * n);
        int32_t rc = synap_voice_debug_ja_bert(v, ids.data(), w2p.data(), n_ids, n, ja.data());
        if (rc != n) { fprintf(stderr, "[%d] debug_ja_bert rc=%d\n", i, rc); allPass = false; continue; }

        std::ifstream rf(refDir + "/bert_ref_int8_" + std::to_string(i) + ".f32", std::ios::binary);
        std::vector<float> ref(static_cast<size_t>(768) * n);
        if (!read_n(rf, ref.data(), ref.size())) { fprintf(stderr, "[%d] missing ref\n", i); allPass = false; continue; }

        const double cos = cosine(ja, ref);
        const bool ok = cos > 0.999;
        allPass = allPass && ok;
        printf("%s [%d] n_ids=%d n=%d  cos(C++ int8, py int8)=%.6f\n", ok ? "PASS" : "FAIL", i, n_ids, n, cos);
    }
    synap_voice_free(v);
    printf("%s\n", allPass ? "ALL PASS" : "FAILURES");
    return allPass ? 0 : 1;
}
