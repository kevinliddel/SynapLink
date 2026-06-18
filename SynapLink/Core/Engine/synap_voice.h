//
//  synap_voice.h
//  SynapLink
//
//  C bridge over the on-device voice-cloning TTS: MeloTTS VITS -> tone-color
//  converter, both ONNX via onnxruntime. One call synthesizes a single text
//  chunk (already g2p'd to phones/tones/lang ids) in a target voice and returns
//  22.05 kHz mono float audio. An optional bert-base-uncased session supplies
//  prosody (ja_bert): given the chunk's WordPiece input_ids + word2ph, the
//  bridge runs BERT and repeats each token's hidden vector into ja_bert[768, n].
//  The Swift layer handles g2p, chunking, inter-chunk silence, and playback.
//

#ifndef SYNAP_VOICE_H
#define SYNAP_VOICE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct SynapVoice SynapVoice;

/// Load the MeloTTS + converter ONNX models, plus an optional prosody BERT
/// (pass NULL to synthesize without intonation / ja_bert=0). Returns NULL on failure.
SynapVoice* synap_voice_create(const char* melo_onnx_path, const char* converter_onnx_path,
                               const char* bert_onnx_path);

void synap_voice_free(SynapVoice* voice);

/// Synthesize one chunk in the target voice.
///   phones/tones/langs : int64 arrays of length `n` (from the g2p frontend)
///   sid                : MeloTTS speaker id (EN-US)
///   src_se / tgt_se    : 256-float speaker embeddings (base source / target voice)
///   input_ids/word2ph  : BERT WordPiece ids (len `n_ids`) + per-id phone counts
///                        (sum == n). Pass NULL / n_ids<=0 for no intonation.
///   out_audio          : receives a malloc'd 22.05 kHz mono float buffer
///   out_stage_ms       : optional; if non-NULL, receives 4 stage timings in ms
///                        [bert, melo, spec, converter] for profiling.
/// Returns the sample count (>0), or a negative error code. Free with
/// synap_voice_free_audio.
int32_t synap_voice_say(SynapVoice* voice,
                        const int64_t* phones, const int64_t* tones, const int64_t* langs,
                        int32_t n, int64_t sid,
                        const float* src_se, const float* tgt_se,
                        const int64_t* input_ids, const int32_t* word2ph, int32_t n_ids,
                        float** out_audio, double* out_stage_ms);

void synap_voice_free_audio(float* audio);

/// Output sample rate of synap_voice_say (22050).
int32_t synap_voice_sample_rate(void);

/// Test-only: run BERT + build ja_bert[768*n] (row-major [768][n]) into the
/// caller-allocated `out_ja`. Returns n on success or <0. The app never calls
/// this; the desktop smoke test uses it to verify ja_bert against MeloTTS.
int32_t synap_voice_debug_ja_bert(SynapVoice* voice,
                                  const int64_t* input_ids, const int32_t* word2ph,
                                  int32_t n_ids, int32_t n, float* out_ja);

#ifdef __cplusplus
}
#endif

#endif /* SYNAP_VOICE_H */
