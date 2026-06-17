#!/usr/bin/env python3
"""
Phase 0 quality demo (no MeloTTS needed):
  text --(macOS `say`)--> base speech --(OpenVoice converter)--> recolored to a
  target voice. Writes outputs/source.wav (the `say` voice) and
  outputs/cloned.wav (recolored to the reference voice) so you can A/B them.

Usage:  clone_test.py [reference_audio] ["text"] [say_voice]
Defaults: the repo's example_reference.mp3, a sample sentence, voice "Samantha".
"""
import os
import subprocess
import sys

import numpy as np
import soundfile as sf
import torch

from export_onnx import find_converter, load_model

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "outputs")
SR = 22050


def to_wav_22k(src, dst):
    # afconvert (CoreAudio) decodes mp3/aiff and resamples to 22.05k mono s16.
    subprocess.run(["afconvert", src, dst, "-d", f"LEI16@{SR}", "-c", "1", "-f", "WAVE"], check=True)


def spectrogram(y, n_fft, hop, win):
    # openvoice.mel_processing.spectrogram_torch, inlined (its module imports
    # librosa, which we don't install). return_complex=True for modern torch.
    window = torch.hann_window(win)
    pad = int((n_fft - hop) / 2)
    y = torch.nn.functional.pad(y.unsqueeze(1), (pad, pad), mode="reflect").squeeze(1)
    spec = torch.stft(y, n_fft, hop_length=hop, win_length=win, window=window,
                      center=False, pad_mode="reflect", normalized=False,
                      onesided=True, return_complex=True)
    spec = torch.view_as_real(spec)
    return torch.sqrt(spec.pow(2).sum(-1) + 1e-6)


def load_se(model, wav_path, hps):
    y, _ = sf.read(wav_path, dtype="float32")
    if y.ndim > 1:
        y = y.mean(axis=1)
    y = torch.FloatTensor(y).unsqueeze(0)
    spec = spectrogram(y, hps.data.filter_length, hps.data.hop_length, hps.data.win_length)
    with torch.no_grad():
        se = model.ref_enc(spec.transpose(1, 2)).unsqueeze(-1)
    return spec, se


def main():
    os.makedirs(OUT, exist_ok=True)
    ref_in = sys.argv[1] if len(sys.argv) > 1 else \
        os.path.join(HERE, "vendor/OpenVoice/resources/example_reference.mp3")
    text = sys.argv[2] if len(sys.argv) > 2 else \
        "Hi! This is a quick test of on-device voice cloning for SynapLink."
    voice = sys.argv[3] if len(sys.argv) > 3 else "Samantha"

    cfg, ckpt = find_converter()
    model, hps = load_model(cfg, ckpt)

    aiff = os.path.join(OUT, "_say.aiff")
    subprocess.run(["say", "-v", voice, "-o", aiff, text], check=True)
    src_wav = os.path.join(OUT, "source.wav")
    ref_wav = os.path.join(OUT, "reference.wav")
    to_wav_22k(aiff, src_wav)
    to_wav_22k(ref_in, ref_wav)

    src_spec, src_se = load_se(model, src_wav, hps)
    _, tgt_se = load_se(model, ref_wav, hps)
    lengths = torch.LongTensor([src_spec.size(-1)])
    with torch.no_grad():
        audio = model.voice_conversion(src_spec, lengths, sid_src=src_se,
                                       sid_tgt=tgt_se, tau=0.3)[0][0, 0].cpu().numpy()
    out = os.path.join(OUT, "cloned.wav")
    sf.write(out, audio.astype(np.float32), SR)

    print("wrote:")
    print("  source :", src_wav, "(macOS", voice + ")")
    print("  target :", ref_wav)
    print("  cloned :", out, "(source content in target voice)")


if __name__ == "__main__":
    main()
