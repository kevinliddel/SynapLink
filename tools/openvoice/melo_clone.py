#!/usr/bin/env python3
"""
Phase 0 V2 end-to-end: real text -> MeloTTS English -> recolor to a target voice
with the OpenVoice V2 converter. This is the TRUE pipeline (no macOS `say`).

Writes outputs/melo_source.wav (MeloTTS) and outputs/melo_cloned.wav (in the
target voice). Uses the V2 base-speaker source SE when available, else extracts
it from the MeloTTS output.

Usage: melo_clone.py [reference_audio] ["text"] [speaker]
"""
import os
import sys

import numpy as np
import soundfile as sf
import torch

from clone_test import spectrogram, to_wav_22k
from export_onnx import find_converter, load_model

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "outputs")
SES = os.path.join(HERE, "checkpoints", "base_speakers", "ses")
SR = 22050


def se_from_wav(model, wav_path, hps):
    y, _ = sf.read(wav_path, dtype="float32")
    if y.ndim > 1:
        y = y.mean(axis=1)
    spec = spectrogram(torch.FloatTensor(y).unsqueeze(0),
                       hps.data.filter_length, hps.data.hop_length, hps.data.win_length)
    with torch.no_grad():
        return spec, model.ref_enc(spec.transpose(1, 2)).unsqueeze(-1)


def main():
    os.makedirs(OUT, exist_ok=True)
    ref_in = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "voices", "riko.wav")
    text = sys.argv[2] if len(sys.argv) > 2 else \
        "Hi! This is a quick test of on-device voice cloning for SynapLink."
    want_speaker = sys.argv[3] if len(sys.argv) > 3 else "EN-US"

    cfg, ckpt = find_converter()
    model, hps = load_model(cfg, ckpt)

    # --- MeloTTS base speech ---
    from melo.api import TTS
    tts = TTS(language="EN", device="cpu")
    spk2id = tts.hps.data.spk2id
    speakers = list(spk2id.keys())  # spk2id is a MeloTTS HParams, not a dict
    speaker = want_speaker if want_speaker in speakers else speakers[0]
    melo_raw = os.path.join(OUT, "_melo_raw.wav")
    tts.tts_to_file(text, spk2id[speaker], melo_raw, speed=1.0)
    print(f"MeloTTS speaker={speaker} (choices: {speakers})")

    src_wav = os.path.join(OUT, "melo_source.wav")
    ref_wav = os.path.join(OUT, "melo_reference.wav")
    to_wav_22k(melo_raw, src_wav)
    to_wav_22k(ref_in, ref_wav)

    src_spec, src_se_fallback = se_from_wav(model, src_wav, hps)
    _, tgt_se = se_from_wav(model, ref_wav, hps)

    # Prefer the matched V2 base-speaker source SE; fall back to ref_enc.
    se_file = os.path.join(SES, speaker.lower().replace("_", "-") + ".pth")
    if os.path.exists(se_file):
        src_se = torch.load(se_file, map_location="cpu", weights_only=False)
        print(f"source SE: {os.path.basename(se_file)}")
    else:
        src_se = src_se_fallback
        print("source SE: extracted from MeloTTS output (no matching base SE)")

    lengths = torch.LongTensor([src_spec.size(-1)])
    with torch.no_grad():
        audio = model.voice_conversion(src_spec, lengths, sid_src=src_se,
                                       sid_tgt=tgt_se, tau=0.3)[0][0, 0].cpu().numpy()
    out = os.path.join(OUT, "melo_cloned.wav")
    sf.write(out, audio.astype(np.float32), SR)
    print("wrote:")
    print("  source :", src_wav, "(MeloTTS English)")
    print("  cloned :", out, "(text in target voice)")


if __name__ == "__main__":
    main()
