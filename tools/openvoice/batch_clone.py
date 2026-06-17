#!/usr/bin/env python3
"""
Recolor one MeloTTS English utterance to ALL configured voices, writing
outputs/clone_<name>.wav for each plus a cosine-to-target check. One MeloTTS
synth, N conversions.

Run with: KMP_DUPLICATE_LIB_OK=TRUE OMP_NUM_THREADS=1 TOKENIZERS_PARALLELISM=false
"""
import os

import soundfile as sf
import torch
import torch.nn.functional as F

from clone_test import spectrogram, to_wav_22k
from export_onnx import find_converter, load_model

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "outputs")
VOICEDIR = os.path.join(HERE, "voices")  # local reference clips (gitignored)
SR = 22050

VOICES = [
    ("riko", "riko.wav", "female"),
    ("akira", "akira.mp3", "female"),
    ("touma", "touma.mp3", "male"),
    ("ayanokoji", "ayanokoji.mp3", "male"),
]
TEXT = "Hello! I'm your on-device assistant. I can read replies aloud in this voice, completely offline."


def se_from_wav(model, wav, hps):
    y, _ = sf.read(wav, dtype="float32")
    if y.ndim > 1:
        y = y.mean(axis=1)
    spec = spectrogram(torch.FloatTensor(y).unsqueeze(0),
                       hps.data.filter_length, hps.data.hop_length, hps.data.win_length)
    with torch.no_grad():
        return spec, model.ref_enc(spec.transpose(1, 2)).unsqueeze(-1)


def main():
    os.makedirs(OUT, exist_ok=True)
    cfg, ckpt = find_converter()
    model, hps = load_model(cfg, ckpt)

    # One MeloTTS source (EN-US) + its base source SE.
    from melo.api import TTS
    tts = TTS(language="EN", device="cpu")
    spk = tts.hps.data.spk2id["EN-US"]
    raw = os.path.join(OUT, "_src.wav")
    tts.tts_to_file(TEXT, spk, raw, speed=1.0)
    src_wav = os.path.join(OUT, "clone_source.wav")
    to_wav_22k(raw, src_wav)
    src_spec, _ = se_from_wav(model, src_wav, hps)
    src_se = torch.load(os.path.join(HERE, "checkpoints/base_speakers/ses/en-us.pth"),
                        map_location="cpu", weights_only=False)
    lengths = torch.LongTensor([src_spec.size(-1)])

    cos = lambda a, b: F.cosine_similarity(a.flatten(), b.flatten(), dim=0).item()
    for name, fname, gender in VOICES:
        ref_wav = os.path.join(OUT, f"_ref_{name}.wav")
        to_wav_22k(os.path.join(VOICEDIR, fname), ref_wav)
        _, tgt = se_from_wav(model, ref_wav, hps)
        with torch.no_grad():
            audio = model.voice_conversion(src_spec, lengths, sid_src=src_se,
                                           sid_tgt=tgt, tau=0.3)[0][0, 0].cpu().numpy()
        out = os.path.join(OUT, f"clone_{name}.wav")
        sf.write(out, audio, SR)
        # similarity of the cloned output back to the target
        _, clo = se_from_wav(model, out, hps)
        print(f"{name:10s} ({gender:6s}) cos(cloned,target)={cos(clo, tgt):+.3f}  -> {os.path.basename(out)}")


if __name__ == "__main__":
    main()
