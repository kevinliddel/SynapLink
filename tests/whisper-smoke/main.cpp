//
//  main.cpp — desktop smoke test for synap_whisper
//
//  Links the macOS slice of whisper.xcframework and the synap_whisper bridge,
//  loads a whisper GGML model, transcribes a 16 kHz mono s16le WAV, and checks
//  the text is non-empty (and optionally contains an expected substring).
//
//  Usage: whisper-smoke <ggml-model.bin> <audio-16k-mono.wav> [expected-substr]
//  Exit codes: 0 ok, 1 usage, 2 load failed, 3 wav read failed, 4 transcribe failed,
//              5 expected substring missing
//

#include "synap_whisper.h"

#include <cctype>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <string>
#include <vector>

namespace {

// Minimal WAV reader for PCM s16le mono at SYNAP_WHISPER_SAMPLE_RATE. Returns
// float samples in [-1, 1]; empty on failure.
std::vector<float> read_wav_s16_mono(const char* path) {
    std::ifstream in(path, std::ios::binary);
    if (!in) { return {}; }
    std::vector<uint8_t> bytes((std::istreambuf_iterator<char>(in)), {});
    if (bytes.size() < 44 || memcmp(bytes.data(), "RIFF", 4) != 0) { return {}; }

    // Walk chunks to find "data".
    size_t pos = 12;
    while (pos + 8 <= bytes.size()) {
        const char* id = reinterpret_cast<const char*>(bytes.data() + pos);
        uint32_t sz;
        memcpy(&sz, bytes.data() + pos + 4, 4);
        if (memcmp(id, "data", 4) == 0) {
            const size_t start = pos + 8;
            const size_t n     = std::min<size_t>(sz, bytes.size() - start) / 2;
            std::vector<float> samples(n);
            for (size_t i = 0; i < n; ++i) {
                int16_t s;
                memcpy(&s, bytes.data() + start + i * 2, 2);
                samples[i] = static_cast<float>(s) / 32768.0f;
            }
            return samples;
        }
        pos += 8 + sz + (sz & 1);
    }
    return {};
}

std::string lower(std::string s) {
    for (auto& c : s) { c = static_cast<char>(std::tolower(static_cast<unsigned char>(c))); }
    return s;
}

} // namespace

int main(int argc, char** argv) {
    setvbuf(stdout, nullptr, _IOLBF, 0);
    if (argc < 3) {
        fprintf(stderr, "usage: %s <ggml-model.bin> <audio.wav> [expected-substr]\n", argv[0]);
        return 1;
    }

    std::vector<float> samples = read_wav_s16_mono(argv[2]);
    if (samples.empty()) {
        fprintf(stderr, "FAIL: could not read 16k mono s16 WAV: %s\n", argv[2]);
        return 3;
    }
    printf("loaded %zu samples (%.1f s @ 16kHz)\n", samples.size(), samples.size() / 16000.0);

    const bool use_gpu = false; // CPU on the Intel dev Mac
    SynapWhisper* w    = synap_whisper_create(argv[1], use_gpu, 4);
    if (!w) {
        fprintf(stderr, "FAIL: whisper model load: %s\n", argv[1]);
        return 2;
    }

    std::vector<char> buf(8 * 1024);
    const int32_t n = synap_whisper_transcribe(w, samples.data(), static_cast<int32_t>(samples.size()), "en",
                                               buf.data(), static_cast<int32_t>(buf.size()));
    synap_whisper_free(w);

    if (n < 0) {
        fprintf(stderr, "FAIL: transcribe rc=%d\n", n);
        return 4;
    }
    printf("transcript: \"%s\"\n", buf.data());

    if (argc > 3) {
        if (lower(buf.data()).find(lower(argv[3])) == std::string::npos) {
            fprintf(stderr, "FAIL: expected substring '%s' not found\n", argv[3]);
            return 5;
        }
        printf("substring '%s' found\n", argv[3]);
    }

    printf("OK: whisper transcription succeeded\n");
    return 0;
}
