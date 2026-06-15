//
//  main.cpp — desktop smoke test for synap_sd
//
//  Links the macOS slice of sd.xcframework + the synap_sd bridge, generates a
//  small image from a prompt, and writes it as a PPM so it can be eyeballed.
//
//  Usage: sd-smoke <model.gguf> <prompt> [size] [steps] [out.ppm]
//  Exit codes: 0 ok, 1 usage, 2 load failed, 3 generate failed
//

#include "synap_sd.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>

int main(int argc, char** argv) {
    setvbuf(stdout, nullptr, _IOLBF, 0);
    if (argc < 3) {
        fprintf(stderr, "usage: %s <model.gguf> <prompt> [size] [steps] [out.ppm]\n", argv[0]);
        return 1;
    }
    const char* model   = argv[1];
    const char* prompt  = argv[2];
    const int32_t size  = argc > 3 ? atoi(argv[3]) : 256;
    const int32_t steps = argc > 4 ? atoi(argv[4]) : 12;
    const char* outPath = argc > 5 ? argv[5] : "/tmp/sd-out.ppm";

    printf("== load ==\n");
    const char* taesd = getenv("SD_TAESD"); // optional tiny VAE override
    SynapSD* sd       = synap_sd_create(model, taesd, 4, false);
    if (!sd) {
        fprintf(stderr, "FAIL: sd model load: %s\n", model);
        return 2;
    }

    printf("== generate %dx%d, %d steps ==\n%s\n", size, size, steps, prompt);
    int32_t w = 0, h = 0;
    uint8_t* rgb = synap_sd_generate(sd, prompt, "", size, size, steps, 7.0f,
                                     /*EULER_A=*/1, /*seed=*/42, &w, &h);
    synap_sd_free(sd);

    if (!rgb || w <= 0 || h <= 0) {
        fprintf(stderr, "FAIL: generate\n");
        return 3;
    }
    printf("generated %dx%d\n", w, h);

    FILE* f = fopen(outPath, "wb");
    if (f) {
        fprintf(f, "P6\n%d %d\n255\n", w, h);
        fwrite(rgb, 1, static_cast<size_t>(w) * h * 3, f);
        fclose(f);
        printf("wrote %s\n", outPath);
    }
    synap_sd_free_rgb(rgb);
    printf("OK: image generation succeeded\n");
    return 0;
}
