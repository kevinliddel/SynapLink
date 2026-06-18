#!/usr/bin/env python3
"""
Re-bake the 256-float speaker embeddings, denoising references that carry
background ambiance (the male clips) before ref_enc so the converter doesn't
reproduce the noise. Clean refs (riko/akira) are baked as-is. Writes assets/
se_<voice>.f32 + prints cosine(old, new) so the change is visible.

Run with: KMP_DUPLICATE_LIB_OK=TRUE OMP_NUM_THREADS=1 TOKENIZERS_PARALLELISM=false
"""
import os
import subprocess

import numpy as np
import soundfile as sf
import torch

from clone_test import spectrogram
from export_onnx import find_converter, load_model

HERE = os.path.dirname(os.path.abspath(__file__))
ASSETS = os.path.join(HERE, "assets")
VOICEDIR = os.path.join(HERE, "voices")
VOICES = {"riko": "riko.wav", "akira": "akira.mp3", "touma": "touma.mp3", "ayanokoji": "ayanokoji.mp3"}
NOISY = set()  # all refs are now clean (male voices were vocal-separated upstream) -> no denoise
LOG = open("/tmp/rebake_se_result.txt", "w")


def to_22k_mono(src, dst, denoise):
    # Match the original bake's resampler exactly (afconvert / CoreAudio); for
    # noisy refs, insert an ffmpeg FFT-denoise pass first so denoise is the ONLY
    # difference vs the clean path (afconvert still does the final 22.05k resample).
    if denoise:
        tmp = dst + ".dn.wav"
        subprocess.run(["ffmpeg", "-y", "-i", src, "-af",
                        "highpass=f=70,afftdn=nr=18:nf=-30", "-ar", "44100", "-ac", "1", tmp],
                       check=True, capture_output=True)
        subprocess.run(["afconvert", tmp, dst, "-d", "LEI16@22050", "-c", "1", "-f", "WAVE"], check=True)
        os.remove(tmp)
    else:
        subprocess.run(["afconvert", src, dst, "-d", "LEI16@22050", "-c", "1", "-f", "WAVE"], check=True)


def main():
    model, hps = load_model(*find_converter())

    def target_se(wav):
        y, _ = sf.read(wav, dtype="float32")
        if y.ndim > 1:
            y = y.mean(axis=1)
        s = spectrogram(torch.FloatTensor(y).unsqueeze(0), hps.data.filter_length,
                        hps.data.hop_length, hps.data.win_length)
        with torch.no_grad():
            return model.ref_enc(s.transpose(1, 2)).flatten().numpy()

    resvoice = os.path.join(HERE, "..", "..", "SynapLink", "Resources", "Voice")
    for name, fname in VOICES.items():
        path = os.path.join(ASSETS, f"se_{name}.f32")
        ref_old = os.path.join(resvoice, f"se_{name}.f32")  # committed original = true baseline
        old = np.fromfile(ref_old, dtype=np.float32) if os.path.exists(ref_old) else None
        tmp = os.path.join(ASSETS, f"_{name}.wav")
        to_22k_mono(os.path.join(VOICEDIR, fname), tmp, name in NOISY)
        se = target_se(tmp).astype(np.float32)
        os.remove(tmp)
        se.tofile(path)
        if old is not None and old.size == se.size:
            cos = float(np.dot(old, se) / (np.linalg.norm(old) * np.linalg.norm(se) + 1e-9))
            LOG.write(f"se_{name}.f32  denoise={name in NOISY}  cos(old,new)={cos:.4f}\n")
        else:
            LOG.write(f"se_{name}.f32  denoise={name in NOISY}  (new)\n")
        LOG.flush()


if __name__ == "__main__":
    main()
    LOG.close()
