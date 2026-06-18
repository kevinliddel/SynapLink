#!/usr/bin/env python3
"""
iOS de-risk: does MeloTTS sound acceptable with the BERT features ZEROED?
If yes, we drop the ~440 MB BERT from the on-device pipeline (feed zeros to the
VITS ONNX). Produces a no-BERT source + its recolor to Riko to A/B against the
with-BERT clone_riko.wav.

Run with: KMP_DUPLICATE_LIB_OK=TRUE OMP_NUM_THREADS=1 TOKENIZERS_PARALLELISM=false
"""
import os

import soundfile as sf
import torch

from clone_test import spectrogram, to_wav_22k
from export_onnx import find_converter, load_model

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "outputs")
SR = 22050
TEXT = "Hello! I'm your on-device assistant. I can read replies aloud in this voice, completely offline."


def se(model, hps, p):
    y, _ = sf.read(p, dtype="float32")
    if y.ndim > 1:
        y = y.mean(axis=1)
    s = spectrogram(torch.FloatTensor(y).unsqueeze(0),
                    hps.data.filter_length, hps.data.hop_length, hps.data.win_length)
    with torch.no_grad():
        return s, model.ref_enc(s.transpose(1, 2)).unsqueeze(-1)


def main():
    cfg, ckpt = find_converter()
    model, hps = load_model(cfg, ckpt)

    from melo.api import TTS
    tts = TTS(language="EN", device="cpu")
    spk = tts.hps.data.spk2id["EN-US"]
    tts.hps.data.disable_bert = True  # zero the BERT features at inference

    raw = os.path.join(OUT, "_nb.wav")
    tts.tts_to_file(TEXT, spk, raw, speed=1.0)
    src = os.path.join(OUT, "melo_source_nobert.wav")
    to_wav_22k(raw, src)

    src_spec, _ = se(model, hps, src)
    rr = os.path.join(OUT, "_riko.wav")
    to_wav_22k(os.path.join(HERE, "voices", "riko.wav"), rr)
    _, tgt = se(model, hps, rr)
    src_se = torch.load(os.path.join(HERE, "checkpoints/base_speakers/ses/en-us.pth"),
                        map_location="cpu", weights_only=False)
    with torch.no_grad():
        audio = model.voice_conversion(src_spec, torch.LongTensor([src_spec.size(-1)]),
                                       sid_src=src_se, sid_tgt=tgt, tau=0.3)[0][0, 0].cpu().numpy()
    out = os.path.join(OUT, "clone_riko_nobert.wav")
    sf.write(out, audio, SR)
    print("wrote:")
    print("  no-BERT source :", src)
    print("  no-BERT cloned :", out, "  (A/B vs clone_riko.wav which uses BERT)")


if __name__ == "__main__":
    main()
