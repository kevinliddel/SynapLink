//
//  main.cpp — desktop smoke test for synap_voice
//
//  Runs the exact bridge the iOS app ships (MeloTTS no-BERT -> tone-color
//  converter, ONNX via onnxruntime, with the vDSP STFT/resample) over the baked
//  test chunks, writing a WAV to A/B against the Python reference
//  (tools/openvoice/outputs/onnx_pauses_riko.wav).
//
//  Usage: voice-smoke <melo.onnx> <converter.onnx> <chunks.bin> <src_se.f32> <tgt_se.f32> <out.wav>
//

#include "synap_voice.h"

#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <vector>

namespace {

struct Chunk {
    std::vector<int64_t> phones, tones, langs;
    float pause = 0.0f;
};

template <typename T>
bool read_n(std::ifstream& in, T* dst, size_t n) {
    return static_cast<bool>(in.read(reinterpret_cast<char*>(dst), static_cast<std::streamsize>(n * sizeof(T))));
}

std::vector<float> read_se(const char* path) {
    std::ifstream in(path, std::ios::binary);
    std::vector<float> v(256);
    if (!read_n(in, v.data(), 256)) { return {}; }
    return v;
}

void write_wav_s16(const char* path, const std::vector<float>& x, int sr) {
    std::ofstream o(path, std::ios::binary);
    int16_t ch = 1, bits = 16, fmt = 1, blockAlign = 2;
    int32_t dataBytes = static_cast<int32_t>(x.size()) * 2, chunkSize = 36 + dataBytes, sub1 = 16, byteRate = sr * 2;
    o.write("RIFF", 4); o.write(reinterpret_cast<char*>(&chunkSize), 4); o.write("WAVE", 4);
    o.write("fmt ", 4); o.write(reinterpret_cast<char*>(&sub1), 4); o.write(reinterpret_cast<char*>(&fmt), 2);
    o.write(reinterpret_cast<char*>(&ch), 2); o.write(reinterpret_cast<char*>(&sr), 4);
    o.write(reinterpret_cast<char*>(&byteRate), 4); o.write(reinterpret_cast<char*>(&blockAlign), 2);
    o.write(reinterpret_cast<char*>(&bits), 2);
    o.write("data", 4); o.write(reinterpret_cast<char*>(&dataBytes), 4);
    for (float f : x) {
        long v = std::lround(f * 32767.0f);
        v = v > 32767 ? 32767 : (v < -32768 ? -32768 : v);
        int16_t s = static_cast<int16_t>(v);
        o.write(reinterpret_cast<char*>(&s), 2);
    }
}

}  // namespace

int main(int argc, char** argv) {
    if (argc < 7) {
        fprintf(stderr, "usage: %s melo.onnx converter.onnx chunks.bin src_se.f32 tgt_se.f32 out.wav\n", argv[0]);
        return 1;
    }
    std::ifstream cin_(argv[3], std::ios::binary);
    int32_t sid = 0, num = 0;
    if (!read_n(cin_, &sid, 1) || !read_n(cin_, &num, 1)) { fprintf(stderr, "bad chunks.bin\n"); return 1; }
    std::vector<Chunk> chunks(num);
    for (auto& c : chunks) {
        int32_t n = 0;
        if (!read_n(cin_, &n, 1) || !read_n(cin_, &c.pause, 1)) { fprintf(stderr, "bad chunk\n"); return 1; }
        c.phones.resize(n); c.tones.resize(n); c.langs.resize(n);
        read_n(cin_, c.phones.data(), n); read_n(cin_, c.tones.data(), n); read_n(cin_, c.langs.data(), n);
    }

    std::vector<float> src = read_se(argv[4]), tgt = read_se(argv[5]);
    if (src.empty() || tgt.empty()) { fprintf(stderr, "bad se file\n"); return 2; }

    SynapVoice* v = synap_voice_create(argv[1], argv[2], nullptr);  // legacy chunks: no ja_bert
    if (!v) { fprintf(stderr, "synap_voice_create failed\n"); return 3; }

    const int sr = synap_voice_sample_rate();
    std::vector<float> out;
    for (size_t i = 0; i < chunks.size(); ++i) {
        const auto& c = chunks[i];
        float* audio = nullptr;
        int32_t n = synap_voice_say(v, c.phones.data(), c.tones.data(), c.langs.data(),
                                    static_cast<int32_t>(c.phones.size()), sid, src.data(), tgt.data(),
                                    nullptr, nullptr, 0, &audio);
        if (n < 0) { fprintf(stderr, "say failed on chunk %zu (rc %d)\n", i, n); synap_voice_free(v); return 4; }
        out.insert(out.end(), audio, audio + n);
        synap_voice_free_audio(audio);
        out.insert(out.end(), static_cast<size_t>(c.pause * sr), 0.0f);
        printf("chunk %zu: %d samples (+%.2fs pause)\n", i, n, c.pause);
    }
    synap_voice_free(v);

    write_wav_s16(argv[6], out, sr);
    printf("OK: wrote %s (%.2f s)\n", argv[6], out.size() / static_cast<double>(sr));
    return 0;
}
