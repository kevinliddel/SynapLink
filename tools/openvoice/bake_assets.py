#!/usr/bin/env python3
"""
Bake the on-device assets:
  - assets/se_<voice>.f32  : 256-float target speaker embeddings (riko/akira/touma/ayanokoji)
  - assets/se_source_en.f32: the MeloTTS EN-US base speaker embedding (voice_conversion sid_src)
  - assets/test_chunks.json: precomputed g2p (phones/tones/lang_ids + pause) for a test
    sentence, so the iOS bridge can be validated BEFORE the Swift g2p port exists.

ref_enc runs only here (bake time) — the device ships only the embeddings, not ref_enc.
Run with: KMP_DUPLICATE_LIB_OK=TRUE OMP_NUM_THREADS=1 TOKENIZERS_PARALLELISM=false
"""
import json
import os
import re
import struct

import numpy as np
import soundfile as sf
import torch

from clone_test import spectrogram, to_wav_22k
from export_onnx import find_converter, load_model

HERE = os.path.dirname(os.path.abspath(__file__))
ASSETS = os.path.join(HERE, "assets")
VOICEDIR = os.path.join(HERE, "voices")
VOICES = {"riko": "riko.wav", "akira": "akira.mp3", "touma": "touma.mp3", "ayanokoji": "ayanokoji.mp3"}
TEXT = ("Hello! I'm your on-device assistant. I can read replies aloud, "
        "completely offline. How can I help you today?")
PAUSE = {",": 0.18, ";": 0.18, ":": 0.18, ".": 0.40, "!": 0.40, "?": 0.40}


def save_f32(vec, path):
    np.asarray(vec, dtype="<f4").tofile(path)  # little-endian float32, 256 values


def main():
    os.makedirs(ASSETS, exist_ok=True)
    model, hps = load_model(*find_converter())

    def target_se(wav):
        y, _ = sf.read(wav, dtype="float32")
        if y.ndim > 1:
            y = y.mean(axis=1)
        s = spectrogram(torch.FloatTensor(y).unsqueeze(0), hps.data.filter_length,
                        hps.data.hop_length, hps.data.win_length)
        with torch.no_grad():
            return model.ref_enc(s.transpose(1, 2)).flatten().numpy()

    for name, fname in VOICES.items():
        tmp = os.path.join(ASSETS, f"_{name}.wav")
        to_wav_22k(os.path.join(VOICEDIR, fname), tmp)
        save_f32(target_se(tmp), os.path.join(ASSETS, f"se_{name}.f32"))
        os.remove(tmp)
        print(f"baked se_{name}.f32")

    src = torch.load(os.path.join(HERE, "checkpoints/base_speakers/ses/en-us.pth"),
                     map_location="cpu", weights_only=False).flatten().numpy()
    save_f32(src, os.path.join(ASSETS, "se_source_en.f32"))
    print("baked se_source_en.f32")

    # precomputed g2p for the test sentence, chunked at punctuation
    from melo.api import TTS
    from melo import utils
    tts = TTS(language="EN", device="cpu")
    tts.hps.data.disable_bert = True
    parts = re.split(r"([.,!?;:])", TEXT)
    chunks, i = [], 0
    while i < len(parts):
        seg = parts[i].strip()
        punct = parts[i + 1] if i + 1 < len(parts) else ""
        if seg:
            _, _, phones, tones, lang_ids = utils.get_text_for_tts_infer(
                seg + punct, "EN", tts.hps, "cpu", tts.symbol_to_id)
            chunks.append({"text": seg + punct,
                           "phones": phones.tolist(), "tones": tones.tolist(),
                           "lang_ids": lang_ids.tolist(), "pause": PAUSE.get(punct, 0.0)})
        i += 2
    meta = {"sampling_rate": hps.data.sampling_rate, "filter_length": hps.data.filter_length,
            "hop_length": hps.data.hop_length, "win_length": hps.data.win_length,
            "melo_sampling_rate": int(tts.hps.data.sampling_rate),
            "sid_en_us": int(tts.hps.data.spk2id["EN-US"]), "chunks": chunks}
    with open(os.path.join(ASSETS, "test_chunks.json"), "w") as f:
        json.dump(meta, f)

    # Flat binary for the C++ voice-smoke test: sid, num_chunks, then per chunk
    # n, pause, n*int64 phones, n*int64 tones, n*int64 langs (all little-endian).
    with open(os.path.join(ASSETS, "test_chunks.bin"), "wb") as f:
        f.write(struct.pack("<i", meta["sid_en_us"]))
        f.write(struct.pack("<i", len(chunks)))
        for c in chunks:
            ph, to, la = c["phones"], c["tones"], c["lang_ids"]
            f.write(struct.pack("<i", len(ph)))
            f.write(struct.pack("<f", c["pause"]))
            f.write(struct.pack(f"<{len(ph)}q", *ph))
            f.write(struct.pack(f"<{len(to)}q", *to))
            f.write(struct.pack(f"<{len(la)}q", *la))
    print(f"wrote test_chunks.json + .bin ({len(chunks)} chunks, melo_sr={meta['melo_sampling_rate']})")


if __name__ == "__main__":
    main()
