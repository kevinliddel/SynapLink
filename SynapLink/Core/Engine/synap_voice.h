//
//  synap_voice.h
//  SynapLink
//
//  C bridge over the on-device voice-cloning TTS: MeloTTS (no-BERT VITS) ->
//  tone-color converter, both ONNX via onnxruntime. One call synthesizes a
//  single text chunk (already g2p'd to phones/tones/lang ids) in a target voice
//  and returns 22.05 kHz mono float audio. The Swift layer handles chunking,
//  inter-chunk silence, and playback.
//

#ifndef SYNAP_VOICE_H
#define SYNAP_VOICE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct SynapVoice SynapVoice;

/// Load the MeloTTS + converter ONNX models. Returns NULL on failure.
SynapVoice* synap_voice_create(const char* melo_onnx_path, const char* converter_onnx_path);

void synap_voice_free(SynapVoice* voice);

/// Synthesize one chunk in the target voice.
///   phones/tones/langs : int64 arrays of length `n` (from the g2p frontend)
///   sid                : MeloTTS speaker id (EN-US)
///   src_se / tgt_se    : 256-float speaker embeddings (base source / target voice)
///   out_audio          : receives a malloc'd 22.05 kHz mono float buffer
/// Returns the sample count (>0), or a negative error code. Free with
/// synap_voice_free_audio.
int32_t synap_voice_say(SynapVoice* voice,
                        const int64_t* phones, const int64_t* tones, const int64_t* langs,
                        int32_t n, int64_t sid,
                        const float* src_se, const float* tgt_se,
                        float** out_audio);

void synap_voice_free_audio(float* audio);

/// Output sample rate of synap_voice_say (22050).
int32_t synap_voice_sample_rate(void);

#ifdef __cplusplus
}
#endif

#endif /* SYNAP_VOICE_H */
