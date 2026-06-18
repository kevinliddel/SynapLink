#!/usr/bin/env python3
"""
Validate the exported melo_en.onnx end to end: g2p frontend -> melo_en.onnx
(no-BERT base speech) -> recolor to Riko with the converter. Proves the
on-device pipeline (the iOS app reimplements only the g2p in Swift).

Writes outputs/onnx_melo_base.wav and outputs/onnx_clone_riko.wav.
Run with: KMP_DUPLICATE_LIB_OK=TRUE OMP_NUM_THREADS=1 TOKENIZERS_PARALLELISM=false
"""
import os

import numpy as np
import onnxruntime as ort
import soundfile as sf
import torch

from clone_test import spectrogram, to_wav_22k
from export_onnx import find_converter, load_model

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "outputs")
ONNX = os.path.join(HERE, "onnx")
TEXT = "Hello! I'm your on-device assistant. I can read replies aloud in this voice, completely offline."


def main():
    from melo.api import TTS
    from melo import utils
    tts = TTS(language="EN", device="cpu")
    tts.hps.data.disable_bert = True
    melo_sr = tts.hps.data.sampling_rate

    # g2p frontend (this is what gets ported to Swift on-device)
    bert, ja_bert, phones, tones, lang_ids = utils.get_text_for_tts_infer(
        TEXT, "EN", tts.hps, "cpu", tts.symbol_to_id)
    sid = np.array([tts.hps.data.spk2id["EN-US"]], dtype=np.int64)

    sess = ort.InferenceSession(os.path.join(ONNX, "melo_en.onnx"))
    base = sess.run(None, {
        "x": phones.unsqueeze(0).numpy(), "x_lengths": np.array([phones.size(0)], dtype=np.int64),
        "sid": sid, "tones": tones.unsqueeze(0).numpy(), "lang_ids": lang_ids.unsqueeze(0).numpy(),
        "bert": bert.unsqueeze(0).numpy(), "ja_bert": ja_bert.unsqueeze(0).numpy(),
    })[0][0, 0]
    base_raw = os.path.join(OUT, "_onnx_base_raw.wav")
    sf.write(base_raw, base.astype(np.float32), melo_sr)
    base_wav = os.path.join(OUT, "onnx_melo_base.wav")
    to_wav_22k(base_raw, base_wav)
    print(f"melo_en.onnx -> {len(base)} samples @ {melo_sr} Hz")

    # recolor to Riko (converter in torch — already validated)
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
    out = os.path.join(OUT, "onnx_clone_riko.wav")
    sf.write(out, audio.astype(np.float32), 22050)
    print("wrote:")
    print("  ONNX base   :", base_wav)
    print("  ONNX->Riko  :", out)


if __name__ == "__main__":
    main()
