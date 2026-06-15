//
//  synap_sd.h
//  SynapLink
//
//  Pure-C bridge to stable-diffusion.cpp — the experimental on-device image
//  generation specialist. Swift imports this via the bridging header; the
//  sd/ggml C++ symbols stay inside sd.xcframework.
//
//  Output is raw RGB (width*height*3 bytes); Swift JPEG-encodes it.
//

#pragma once

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct SynapSD SynapSD;

/// Load a Stable Diffusion GGUF (full checkpoint). `taesd_path` is an optional
/// tiny VAE for memory-light decoding (NULL to use the checkpoint's VAE).
/// Returns NULL on failure.
SynapSD* synap_sd_create(const char* model_path, const char* taesd_path, int32_t n_threads, bool use_gpu);

void synap_sd_free(SynapSD* sd);

/// Generate one image. `sample_method` is a sample_method_t raw value
/// (0 = EULER, 1 = EULER_A, 9 = LCM). Returns a malloc'd RGB buffer of
/// (*out_width * *out_height * 3) bytes — free with synap_sd_free_rgb — or
/// NULL on failure.
uint8_t* synap_sd_generate(SynapSD* sd, const char* prompt, const char* negative_prompt, int32_t width, int32_t height,
                           int32_t steps, float cfg_scale, int32_t sample_method, int64_t seed, int32_t* out_width,
                           int32_t* out_height);

void synap_sd_free_rgb(uint8_t* rgb);

#ifdef __cplusplus
}
#endif
