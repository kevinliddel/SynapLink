#!/usr/bin/env python3
"""
Add natural pauses without BERT: split text at punctuation, synthesize each
chunk via melo_en.onnx, and insert silence proportional to the punctuation, then
recolor to Riko. This is exactly the chunking the on-device synap_voice bridge
will do. Writes outputs/onnx_pauses_base.wav and outputs/onnx_pauses_riko.wav.

Run with: KMP_DUPLICATE_LIB_OK=TRUE OMP_NUM_THREADS=1 TOKENIZERS_PARALLELISM=false
"""
import os
import re

import numpy as np
import onnxruntime as ort
import soundfile as sf
import torch

from clone_test import spectrogram, to_wav_22k
from export_onnx import find_converter, load_model

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "outputs")
ONNX = os.path.join(HERE, "onnx")
TEXT = ("Hello! I'm your on-device assistant. I can read replies aloud, "
        "completely offline. How can I help you today?")
PAUSE = {",": 0.18, ";": 0.18, ":": 0.18, ".": 0.40, "!": 0.40, "?": 0.40}


def split_chunks(text):
    parts = re.split(r"([.,!?;:])", text)
    out, i = [], 0
    while i < len(parts):
        seg = parts[i].strip()
        punct = parts[i + 1] if i + 1 < len(parts) else ""
        if seg:
            out.append((seg + punct, PAUSE.get(punct, 0.0)))
        i += 2
    return out


def main():
    from melo.api import TTS
    from melo import utils
    tts = TTS(language="EN", device="cpu")
    tts.hps.data.disable_bert = True
    sr = tts.hps.data.sampling_rate
    sid = np.array([tts.hps.data.spk2id["EN-US"]], dtype=np.int64)
    sess = ort.InferenceSession(os.path.join(ONNX, "melo_en.onnx"))

    pieces = []
    for seg, pause in split_chunks(TEXT):
        bert, ja_bert, phones, tones, lang_ids = utils.get_text_for_tts_infer(
            seg, "EN", tts.hps, "cpu", tts.symbol_to_id)
        audio = sess.run(None, {
            "x": phones.unsqueeze(0).numpy(), "x_lengths": np.array([phones.size(0)], dtype=np.int64),
            "sid": sid, "tones": tones.unsqueeze(0).numpy(), "lang_ids": lang_ids.unsqueeze(0).numpy(),
            "bert": bert.unsqueeze(0).numpy(), "ja_bert": ja_bert.unsqueeze(0).numpy(),
        })[0][0, 0]
        pieces.append(audio.astype(np.float32))
        if pause > 0:
            pieces.append(np.zeros(int(sr * pause), dtype=np.float32))
        print(f"  chunk ({pause:.2f}s pause): {seg}")
    base = np.concatenate(pieces)

    base_raw = os.path.join(OUT, "_pause_raw.wav")
    sf.write(base_raw, base, sr)
    base_wav = os.path.join(OUT, "onnx_pauses_base.wav")
    to_wav_22k(base_raw, base_wav)

    model, hps = load_model(*find_converter())
    def se(p):
        y, _ = sf.read(p, dtype="float32")
        if y.ndim > 1:
            y = y.mean(axis=1)
        s = spectrogram(torch.FloatTensor(y).unsqueeze(0), hps.data.filter_length,
                        hps.data.hop_length, hps.data.win_length)
        with torch.no_grad():
            return s, model.ref_enc(s.transpose(1, 2)).unsqueeze(-1)
    src_spec, _ = se(base_wav)
    rr = os.path.join(OUT, "_riko.wav")
    to_wav_22k(os.path.join(HERE, "voices", "riko.wav"), rr)
    _, tgt = se(rr)
    src_se = torch.load(os.path.join(HERE, "checkpoints/base_speakers/ses/en-us.pth"),
                        map_location="cpu", weights_only=False)
    with torch.no_grad():
        audio = model.voice_conversion(src_spec, torch.LongTensor([src_spec.size(-1)]),
                                       sid_src=src_se, sid_tgt=tgt, tau=0.3)[0][0, 0].cpu().numpy()
    out = os.path.join(OUT, "onnx_pauses_riko.wav")
    sf.write(out, audio.astype(np.float32), 22050)
    print("wrote:", base_wav, "and", out)


if __name__ == "__main__":
    main()
