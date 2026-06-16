//
//  synap_sd.cpp
//  SynapLink
//
//  C++ implementation of the synap_sd bridge over stable-diffusion.cpp.
//

#include "synap_sd.h"

#include <sd/stable-diffusion.h>

#include <cstdio>
#include <cstdlib>
#include <cstring>

struct SynapSD {
    sd_ctx_t* ctx = nullptr;
};

// stable-diffusion.cpp logs verbosely at DEBUG/INFO (per-tensor) — drop those
// so they don't flood logs / temp space. WARN/ERROR are forwarded to stderr:
// they carry the reason for failures and aborts (out-of-memory, unsupported
// op, etc.), which is essential for diagnosing on-device crashes.
static void sd_silent_log(enum sd_log_level_t level, const char* text, void* data) {
    (void)data;
    if (level >= SD_LOG_WARN && text) { fputs(text, stderr); }
}

static void sd_silent_progress(int step, int steps, float time, void* data) {
    (void)step;
    (void)steps;
    (void)time;
    (void)data;
}

SynapSD* synap_sd_create(const char* model_path, const char* taesd_path, int32_t n_threads, bool use_gpu) {
    if (!model_path) { return nullptr; }

    sd_set_log_callback(sd_silent_log, nullptr);
    sd_set_progress_callback(sd_silent_progress, nullptr);

    sd_ctx_params_t params;
    sd_ctx_params_init(&params);
    params.model_path = model_path;
    if (taesd_path && taesd_path[0] != '\0') { params.taesd_path = taesd_path; }
    params.n_threads = n_threads > 0 ? n_threads : 4;
    // mmap avoids loading all weights into anonymous RAM. Flash attention is
    // left at the init default (off): forcing it produced blank output on the
    // CPU backend, and it is not reliably supported across SD backends.
    params.enable_mmap = true;
    // Backend selection: default resolves GPU-first, which is correct on an
    // Apple-GPU device (Metal). On hosts whose only GPU is non-Apple (the
    // Intel dev Mac, the simulator) Metal produces garbage, so pin to CPU.
    params.backend = use_gpu ? nullptr : "CPU";

    sd_ctx_t* ctx = new_sd_ctx(&params);
    if (!ctx) { return nullptr; }

    auto* sd = new SynapSD();
    sd->ctx  = ctx;
    return sd;
}

void synap_sd_free(SynapSD* sd) {
    if (!sd) { return; }
    if (sd->ctx) { free_sd_ctx(sd->ctx); }
    delete sd;
}

uint8_t* synap_sd_generate(SynapSD* sd, const char* prompt, const char* negative_prompt, int32_t width, int32_t height,
                           int32_t steps, float cfg_scale, int32_t sample_method, int64_t seed, int32_t* out_width,
                           int32_t* out_height) {
    if (!sd || !sd->ctx || !prompt) { return nullptr; }

    sd_img_gen_params_t g;
    sd_img_gen_params_init(&g);
    g.prompt                         = prompt;
    g.negative_prompt                = negative_prompt ? negative_prompt : "";
    g.width                          = width;
    g.height                         = height;
    g.sample_params.sample_steps     = steps;
    g.sample_params.guidance.txt_cfg = cfg_scale;
    g.sample_params.sample_method    = static_cast<enum sample_method_t>(sample_method);
    g.seed                           = seed;
    g.batch_count                    = 1;

    sd_image_t* images = generate_image(sd->ctx, &g);
    if (!images || !images[0].data) {
        if (images) { free_sd_images(images, 1); }
        return nullptr;
    }

    const sd_image_t img = images[0];
    const size_t bytes   = static_cast<size_t>(img.width) * img.height * img.channel;
    // Normalize to 3-channel RGB for the caller.
    uint8_t* out = static_cast<uint8_t*>(malloc(static_cast<size_t>(img.width) * img.height * 3));
    if (out) {
        if (img.channel == 3) {
            memcpy(out, img.data, bytes);
        } else {
            for (uint32_t i = 0; i < img.width * img.height; ++i) {
                out[i * 3 + 0] = img.data[i * img.channel + 0];
                out[i * 3 + 1] = img.data[i * img.channel + (img.channel > 1 ? 1 : 0)];
                out[i * 3 + 2] = img.data[i * img.channel + (img.channel > 2 ? 2 : 0)];
            }
        }
        if (out_width) { *out_width = static_cast<int32_t>(img.width); }
        if (out_height) { *out_height = static_cast<int32_t>(img.height); }
    }
    free_sd_images(images, 1);
    return out;
}

void synap_sd_free_rgb(uint8_t* rgb) {
    free(rgb);
}
