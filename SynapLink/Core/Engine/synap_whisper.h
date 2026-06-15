//
//  synap_whisper.h
//  SynapLink
//
//  Pure-C bridge to whisper.cpp — on-device speech-to-text for the iPhone 11
//  tier (the omni Gemma 4 E2B audio path can't fit in 4 GB). Swift imports
//  this through the bridging header; the whisper/ggml C++ symbols stay inside
//  the whisper.xcframework.
//
//  Audio contract: mono float32 PCM at 16 kHz (SYNAP_WHISPER_SAMPLE_RATE).
//  The caller decodes the recording to that format (AVAudioConverter).
//

#pragma once

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

#define SYNAP_WHISPER_SAMPLE_RATE 16000

/// Opaque transcriber. Swift holds this as `OpaquePointer`.
typedef struct SynapWhisper SynapWhisper;

/// Load a whisper GGML model (ggml-tiny.bin / ggml-base.bin ...). `use_gpu`
/// runs the encoder on Metal where available. Returns NULL on failure.
SynapWhisper* synap_whisper_create(const char* model_path, bool use_gpu, int32_t n_threads);

/// Release the model and all state.
void synap_whisper_free(SynapWhisper* whisper);

/// Transcribe mono float32 PCM at 16 kHz. `language` is an ISO code
/// ("en", "fr", ...) or NULL/"auto" to auto-detect. The recognized text is
/// written to `out_buf` (null-terminated). Returns the number of bytes
/// written (excluding null), or negative on error:
///   -1 invalid arguments   -2 transcription failed
int32_t synap_whisper_transcribe(SynapWhisper* whisper, const float* samples, int32_t n_samples, const char* language,
                                 char* out_buf, int32_t out_buf_size);

#ifdef __cplusplus
}
#endif
