#!/usr/bin/env python3
"""
iOS step: export the MeloTTS EN VITS (no-BERT) to ONNX -> onnx/melo_en.onnx.
Inputs are produced by the g2p frontend (phones/tones/lang_ids); BERT features
are fed as zeros (no-BERT decision). Deterministic config (sdp_ratio=0) for a
clean export.

Run with: KMP_DUPLICATE_LIB_OK=TRUE OMP_NUM_THREADS=1 TOKENIZERS_PARALLELISM=false
"""
import os

import torch

HERE = os.path.dirname(os.path.abspath(__file__))
ONNX = os.path.join(HERE, "onnx")
OPSET = 17


def strip_weight_norm(module):
    for sub in module.modules():
        for name in ("remove_weight_norm", "remove_parametrizations"):
            fn = getattr(sub, name, None)
            if callable(fn):
                try:
                    fn()
                except Exception:
                    pass


def main():
    os.makedirs(ONNX, exist_ok=True)
    from melo.api import TTS
    from melo import utils

    tts = TTS(language="EN", device="cpu")
    tts.hps.data.disable_bert = True
    model = tts.model.eval()
    strip_weight_norm(model)

    bert, ja_bert, phones, tones, lang_ids = utils.get_text_for_tts_infer(
        "Hello there, this is a test.", "EN", tts.hps, "cpu", tts.symbol_to_id)
    x = phones.unsqueeze(0)
    x_len = torch.LongTensor([phones.size(0)])
    tone = tones.unsqueeze(0)
    lang = lang_ids.unsqueeze(0)
    bert = bert.unsqueeze(0)
    ja_bert = ja_bert.unsqueeze(0)
    sid = torch.LongTensor([tts.hps.data.spk2id["EN-US"]])

    class Wrap(torch.nn.Module):
        def __init__(self, m):
            super().__init__()
            self.m = m

        def forward(self, x, x_len, sid, tone, lang, bert, ja_bert):
            return self.m.infer(x, x_len, sid, tone, lang, bert, ja_bert,
                                noise_scale=0.6, length_scale=1.0,
                                noise_scale_w=0.8, sdp_ratio=0.0)[0]

    out = os.path.join(ONNX, "melo_en.onnx")
    torch.onnx.export(
        Wrap(model), (x, x_len, sid, tone, lang, bert, ja_bert), out,
        input_names=["x", "x_lengths", "sid", "tones", "lang_ids", "bert", "ja_bert"],
        output_names=["audio"],
        dynamic_axes={"x": {1: "T"}, "tones": {1: "T"}, "lang_ids": {1: "T"},
                      "bert": {2: "T"}, "ja_bert": {2: "T"}, "audio": {2: "N"}},
        opset_version=OPSET)
    print("exported", out)

    # parity: PyTorch vs onnxruntime on the same inputs
    import numpy as np
    import onnxruntime as ort
    with torch.no_grad():
        pt = Wrap(model)(x, x_len, sid, tone, lang, bert, ja_bert).numpy()
    sess = ort.InferenceSession(out)
    ox = sess.run(None, {"x": x.numpy(), "x_lengths": x_len.numpy(), "sid": sid.numpy(),
                         "tones": tone.numpy(), "lang_ids": lang.numpy(),
                         "bert": bert.numpy(), "ja_bert": ja_bert.numpy()})[0]
    print(f"shapes pt={pt.shape} ox={ox.shape}  max|Δ|={np.abs(pt[..., :min(pt.shape[-1], ox.shape[-1])] - ox[..., :min(pt.shape[-1], ox.shape[-1])]).max():.2e}")


if __name__ == "__main__":
    main()
