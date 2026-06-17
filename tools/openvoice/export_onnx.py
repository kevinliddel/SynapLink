#!/usr/bin/env python3
"""
Phase 0: export the OpenVoice V1 tone-color converter to ONNX and check parity.

Grounded in openvoice/api.py:
  - ref_enc:           spec[B,T,spec_ch] -> g[B,gin]      (speaker embedding)
  - voice_conversion:  spec[B,spec_ch,T], lengths, src_se[B,gin,1], tgt_se[B,gin,1]
                       -> audio[B,1,N]                    (the recolor)
The STFT (spectrogram_torch) is computed on-device with vDSP, so it is fed as an
input rather than exported.

This is a PROTOTYPE: the flow + HiFi-GAN decoder use weight-norm and a few ops
that can trip torch.onnx.export. We strip weight-norm first; if an op is
unsupported, bump the opset or replace the op, then re-run.
"""
import glob
import os
import time

import numpy as np
import torch

HERE = os.path.dirname(os.path.abspath(__file__))
ONNX_DIR = os.path.join(HERE, "onnx")
OPSET = 17  # 17 has STFT/LayerNorm; raise if an op is missing.


def find_converter():
    base = os.path.join(HERE, "checkpoints")
    cfg = glob.glob(os.path.join(base, "**", "converter", "config.json"), recursive=True)
    ckpt = glob.glob(os.path.join(base, "**", "converter", "checkpoint.pth"), recursive=True)
    if not cfg or not ckpt:
        raise SystemExit("converter checkpoint not found — run setup.sh first")
    return cfg[0], ckpt[0]


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
    from openvoice.api import ToneColorConverter

    os.makedirs(ONNX_DIR, exist_ok=True)
    cfg, ckpt = find_converter()
    print(f"converter: {ckpt}")

    conv = ToneColorConverter(cfg, device="cpu")
    conv.load_ckpt(ckpt)
    model = conv.model.eval()
    hps = conv.hps

    spec_ch = hps.data.filter_length // 2 + 1
    gin = model.ref_enc.proj.out_features if hasattr(model.ref_enc, "proj") else 256
    print(f"spec_channels={spec_ch} gin_channels={gin}")

    # ---- ref_enc: spec[B,T,spec_ch] -> g[B,gin] ----
    class RefEnc(torch.nn.Module):
        def __init__(self, m):
            super().__init__()
            self.ref_enc = m.ref_enc

        def forward(self, spec_t):  # [B, T, spec_ch]
            return self.ref_enc(spec_t)

    dummy_spec_t = torch.randn(1, 128, spec_ch)
    torch.onnx.export(
        RefEnc(model), (dummy_spec_t,), os.path.join(ONNX_DIR, "ref_enc.onnx"),
        input_names=["spec_t"], output_names=["g"],
        dynamic_axes={"spec_t": {1: "T"}}, opset_version=OPSET)
    print("exported ref_enc.onnx")

    # ---- voice_conversion: spec[B,spec_ch,T], lengths, src_se, tgt_se -> audio ----
    strip_weight_norm(model)
    tau = float(getattr(hps, "tau", 0.3) or 0.3)

    class Converter(torch.nn.Module):
        def __init__(self, m, tau):
            super().__init__()
            self.m = m
            self.tau = tau

        def forward(self, spec, lengths, src_se, tgt_se):
            return self.m.voice_conversion(spec, lengths, sid_src=src_se,
                                           sid_tgt=tgt_se, tau=self.tau)[0]

    T = 160
    spec = torch.randn(1, spec_ch, T)
    lengths = torch.LongTensor([T])
    src_se = torch.randn(1, gin, 1)
    tgt_se = torch.randn(1, gin, 1)
    torch.onnx.export(
        Converter(model, tau), (spec, lengths, src_se, tgt_se),
        os.path.join(ONNX_DIR, "voice_conversion.onnx"),
        input_names=["spec", "lengths", "src_se", "tgt_se"], output_names=["audio"],
        dynamic_axes={"spec": {2: "T"}, "audio": {2: "N"}}, opset_version=OPSET)
    print("exported voice_conversion.onnx")

    # ---- parity check (PyTorch vs onnxruntime) ----
    import onnxruntime as ort
    with torch.no_grad():
        ref_pt = RefEnc(model)(dummy_spec_t).numpy()
    sess = ort.InferenceSession(os.path.join(ONNX_DIR, "ref_enc.onnx"))
    ref_ox = sess.run(None, {"spec_t": dummy_spec_t.numpy()})[0]
    print(f"ref_enc max|Δ| = {np.abs(ref_pt - ref_ox).max():.2e}")

    t0 = time.time()
    with torch.no_grad():
        a_pt = Converter(model, tau)(spec, lengths, src_se, tgt_se).numpy()
    t_pt = time.time() - t0
    sess2 = ort.InferenceSession(os.path.join(ONNX_DIR, "voice_conversion.onnx"))
    t0 = time.time()
    a_ox = sess2.run(None, {"spec": spec.numpy(), "lengths": lengths.numpy(),
                            "src_se": src_se.numpy(), "tgt_se": tgt_se.numpy()})[0]
    t_ox = time.time() - t0
    print(f"voice_conversion max|Δ| = {np.abs(a_pt - a_ox).max():.2e}")
    print(f"timing (T={T} frames ≈ {T * hps.data.hop_length / hps.data.sampling_rate:.1f}s audio): "
          f"torch {t_pt:.2f}s, onnx {t_ox:.2f}s  (A13 will be ~5–10× slower)")

    print("\nNEXT: base TTS (V1 BaseSpeakerTTS.model.infer) export — stochastic "
          "duration predictor needs care; or move to V2/MeloTTS for production.")


if __name__ == "__main__":
    main()
