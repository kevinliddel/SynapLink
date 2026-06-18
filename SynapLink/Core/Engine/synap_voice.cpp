//
//  synap_voice.cpp
//  SynapLink
//
//  MeloTTS (no-BERT) -> tone-color converter, both ONNX via onnxruntime.
//  The STFT between them MUST match openvoice's spectrogram_torch exactly
//  (periodic Hann, reflect pad (n_fft-hop)/2, center=False, magnitude
//  sqrt(re^2+im^2+1e-6)), or the converter gets a bad spectrogram. Accelerate
//  (vDSP) does the FFT and the 2:1 resample (MeloTTS is 44.1 kHz, the converter
//  wants 22.05 kHz).
//

#include "synap_voice.h"

#include <onnxruntime/onnxruntime_cxx_api.h>

#include <Accelerate/Accelerate.h>

#include <cmath>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

namespace {

constexpr int kNFFT = 1024;
constexpr int kHop = 256;
constexpr int kWin = 1024;
constexpr int kSpecBins = kNFFT / 2 + 1;  // 513
constexpr int kLog2N = 10;                // 1024
constexpr int kReflectPad = (kNFFT - kHop) / 2;  // 384
constexpr int kOutSR = 22050;  // converter rate; MeloTTS (44.1k) is decimated 2:1
constexpr int kLPTaps = 64;  // 2:1 anti-alias lowpass

std::vector<float> make_lowpass() {
    // Hann-windowed sinc, cutoff 0.25 cycles/sample (= 11.025 kHz at 44.1 kHz).
    std::vector<float> h(kLPTaps);
    const double fc = 0.25, mid = (kLPTaps - 1) / 2.0;
    double sum = 0;
    for (int n = 0; n < kLPTaps; ++n) {
        double x = n - mid;
        double sinc = (x == 0.0) ? 2.0 * fc : std::sin(2.0 * M_PI * fc * x) / (M_PI * x);
        double w = 0.5 - 0.5 * std::cos(2.0 * M_PI * n / (kLPTaps - 1));
        h[n] = static_cast<float>(sinc * w);
        sum += h[n];
    }
    for (float& v : h) { v /= static_cast<float>(sum); }  // unity DC gain
    return h;
}

}  // namespace

struct SynapVoice {
    Ort::Env env{ORT_LOGGING_LEVEL_WARNING, "synap_voice"};
    Ort::Session melo{nullptr};
    Ort::Session converter{nullptr};
    Ort::MemoryInfo mem = Ort::MemoryInfo::CreateCpu(OrtArenaAllocator, OrtMemTypeDefault);
    FFTSetup fft = nullptr;
    std::vector<float> hann;     // periodic Hann(1024)
    std::vector<float> lowpass;  // 2:1 decimation FIR

    // --- reflect-pad + STFT magnitude, matching spectrogram_torch ---
    std::vector<float> stft(const std::vector<float>& y, int& n_frames) {
        const int n = static_cast<int>(y.size());
        const int padded = n + 2 * kReflectPad;
        std::vector<float> p(padded);
        for (int i = 0; i < kReflectPad; ++i) { p[i] = y[kReflectPad - i]; }          // left reflect (excl. y[0])
        std::memcpy(p.data() + kReflectPad, y.data(), n * sizeof(float));
        for (int i = 0; i < kReflectPad; ++i) { p[kReflectPad + n + i] = y[n - 2 - i]; }  // right reflect

        n_frames = 1 + (padded - kNFFT) / kHop;
        std::vector<float> spec(static_cast<size_t>(kSpecBins) * n_frames);  // [bin][frame]

        std::vector<float> frame(kNFFT), realp(kNFFT / 2), imagp(kNFFT / 2);
        DSPSplitComplex split{realp.data(), imagp.data()};
        for (int f = 0; f < n_frames; ++f) {
            const int start = f * kHop;
            vDSP_vmul(p.data() + start, 1, hann.data(), 1, frame.data(), 1, kNFFT);
            vDSP_ctoz(reinterpret_cast<DSPComplex*>(frame.data()), 2, &split, 1, kNFFT / 2);
            vDSP_fft_zrip(fft, &split, 1, kLog2N, FFT_FORWARD);
            // vDSP packs DC in realp[0], Nyquist in imagp[0], and scales by 2.
            const float dc = 0.5f * realp[0];
            const float nyq = 0.5f * imagp[0];
            spec[static_cast<size_t>(0) * n_frames + f] = std::sqrt(dc * dc + 1e-6f);
            for (int k = 1; k < kNFFT / 2; ++k) {
                const float re = 0.5f * realp[k], im = 0.5f * imagp[k];
                spec[static_cast<size_t>(k) * n_frames + f] = std::sqrt(re * re + im * im + 1e-6f);
            }
            spec[static_cast<size_t>(kNFFT / 2) * n_frames + f] = std::sqrt(nyq * nyq + 1e-6f);
        }
        return spec;
    }

    // --- 2:1 anti-aliased decimation, 44.1 kHz -> 22.05 kHz ---
    std::vector<float> resample_half(const float* x, int n) {
        const int outN = n / 2, half = kLPTaps / 2;
        std::vector<float> out(outN, 0.0f);
        for (int m = 0; m < outN; ++m) {
            const int center = m * 2;
            float acc = 0;
            for (int k = 0; k < kLPTaps; ++k) {
                const int idx = center - half + k;
                if (idx >= 0 && idx < n) { acc += x[idx] * lowpass[k]; }
            }
            out[m] = acc;
        }
        return out;
    }
};

extern "C" {

SynapVoice* synap_voice_create(const char* melo_path, const char* converter_path) {
    if (!melo_path || !converter_path) { return nullptr; }
    try {
        auto* v = new SynapVoice();
        Ort::SessionOptions opt;
        opt.SetIntraOpNumThreads(2);
        opt.SetGraphOptimizationLevel(GraphOptimizationLevel::ORT_ENABLE_ALL);
        v->melo = Ort::Session(v->env, melo_path, opt);
        v->converter = Ort::Session(v->env, converter_path, opt);
        v->fft = vDSP_create_fftsetup(kLog2N, FFT_RADIX2);
        v->hann.resize(kWin);
        for (int i = 0; i < kWin; ++i) { v->hann[i] = 0.5f - 0.5f * std::cos(2.0f * M_PI * i / kWin); }
        v->lowpass = make_lowpass();
        if (!v->fft) { delete v; return nullptr; }
        return v;
    } catch (const std::exception&) {
        return nullptr;
    }
}

void synap_voice_free(SynapVoice* v) {
    if (!v) { return; }
    if (v->fft) { vDSP_destroy_fftsetup(v->fft); }
    delete v;
}

int32_t synap_voice_say(SynapVoice* v,
                        const int64_t* phones, const int64_t* tones, const int64_t* langs,
                        int32_t n, int64_t sid, const float* src_se, const float* tgt_se,
                        float** out_audio) {
    if (!v || !phones || !tones || !langs || n <= 0 || !src_se || !tgt_se || !out_audio) { return -1; }
    try {
        // ---- MeloTTS: phones/tones/langs (+ zero BERT) -> 44.1 kHz audio ----
        const int64_t len = n;
        std::vector<int64_t> shape_seq{1, len};
        std::vector<float> bert_f(static_cast<size_t>(1024) * n, 0.0f);   // no-BERT: zeros
        std::vector<float> ja_bert_f(static_cast<size_t>(768) * n, 0.0f);
        int64_t xlen = len, sidv = sid;
        std::vector<int64_t> shape_bert{1, 1024, len}, shape_ja{1, 768, len}, one{1};

        Ort::Value melo_in[] = {
            Ort::Value::CreateTensor<int64_t>(v->mem, const_cast<int64_t*>(phones), n, shape_seq.data(), 2),
            Ort::Value::CreateTensor<int64_t>(v->mem, &xlen, 1, one.data(), 1),
            Ort::Value::CreateTensor<int64_t>(v->mem, &sidv, 1, one.data(), 1),
            Ort::Value::CreateTensor<int64_t>(v->mem, const_cast<int64_t*>(tones), n, shape_seq.data(), 2),
            Ort::Value::CreateTensor<int64_t>(v->mem, const_cast<int64_t*>(langs), n, shape_seq.data(), 2),
            Ort::Value::CreateTensor<float>(v->mem, bert_f.data(), bert_f.size(), shape_bert.data(), 3),
            Ort::Value::CreateTensor<float>(v->mem, ja_bert_f.data(), ja_bert_f.size(), shape_ja.data(), 3),
        };
        const char* melo_in_names[] = {"x", "x_lengths", "sid", "tones", "lang_ids", "bert", "ja_bert"};
        const char* melo_out_names[] = {"audio"};
        auto melo_out = v->melo.Run(Ort::RunOptions{nullptr}, melo_in_names, melo_in, 7, melo_out_names, 1);
        float* a44 = melo_out[0].GetTensorMutableData<float>();
        auto a44_shape = melo_out[0].GetTensorTypeAndShapeInfo().GetShape();
        int n44 = static_cast<int>(a44_shape[a44_shape.size() - 1]);

        // ---- resample 44.1k -> 22.05k, STFT ----
        std::vector<float> a22 = v->resample_half(a44, n44);
        int n_frames = 0;
        std::vector<float> spec = v->stft(a22, n_frames);

        // ---- converter: spec + source/target embeddings -> 22.05 kHz audio ----
        int64_t t = n_frames;
        std::vector<int64_t> shape_spec{1, kSpecBins, t}, shape_se{1, 256, 1};
        Ort::Value conv_in[] = {
            Ort::Value::CreateTensor<float>(v->mem, spec.data(), spec.size(), shape_spec.data(), 3),
            Ort::Value::CreateTensor<int64_t>(v->mem, &t, 1, one.data(), 1),
            Ort::Value::CreateTensor<float>(v->mem, const_cast<float*>(src_se), 256, shape_se.data(), 3),
            Ort::Value::CreateTensor<float>(v->mem, const_cast<float*>(tgt_se), 256, shape_se.data(), 3),
        };
        const char* conv_in_names[] = {"spec", "lengths", "src_se", "tgt_se"};
        const char* conv_out_names[] = {"audio"};
        auto conv_out = v->converter.Run(Ort::RunOptions{nullptr}, conv_in_names, conv_in, 4, conv_out_names, 1);
        float* aout = conv_out[0].GetTensorMutableData<float>();
        auto out_shape = conv_out[0].GetTensorTypeAndShapeInfo().GetShape();
        int nout = static_cast<int>(out_shape[out_shape.size() - 1]);

        float* buf = static_cast<float*>(std::malloc(static_cast<size_t>(nout) * sizeof(float)));
        if (!buf) { return -2; }
        std::memcpy(buf, aout, static_cast<size_t>(nout) * sizeof(float));
        *out_audio = buf;
        return nout;
    } catch (const std::exception&) {
        return -3;
    }
}

void synap_voice_free_audio(float* audio) { std::free(audio); }

int32_t synap_voice_sample_rate(void) { return kOutSR; }

}  // extern "C"
