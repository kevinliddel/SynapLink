#!/usr/bin/env python3
"""
Phase 0: export the OpenVoice V1 tone-color converter to ONNX and check parity.

We build the model DIRECTLY from openvoice.models (pure torch+numpy), bypassing
openvoice.api — that avoids librosa/numba/llvmlite and the text frontend, which
the converter doesn't need.

Exports (the STFT is fed as input — computed natively with vDSP on-device):
  - ref_enc.onnx           spec[B,T,spec_ch] -> g[B,gin]    (speaker embedding)
  - voice_conversion.onnx  spec[B,spec_ch,T], lengths, src_se[B,gin,1],
                           tgt_se[B,gin,1] -> audio[B,1,N]  (the recolor)

PROTOTYPE: the flow + HiFi-GAN decoder use weight-norm and a few ops that can
trip torch.onnx.export. We strip weight-norm first; if an op is unsupported,
raise the opset or replace it and re-run.
"""
import glob
import os
import time

import numpy as np
import torch

HERE = os.path.dirname(os.path.abspath(__file__))
ONNX_DIR = os.path.join(HERE, "onnx")
OPSET = 17


def find_converter():
    base = os.path.join(HERE, "checkpoints")
    cfg = glob.glob(os.path.join(base, "**", "converter", "config.json"), recursive=True)
    ckpt = glob.glob(os.path.join(base, "**", "converter", "checkpoint.pth"), recursive=True)
    if not cfg or not ckpt:
        raise SystemExit("converter checkpoint not found under checkpoints/ — run setup.sh")
    return cfg[0], ckpt[0]


def load_model(cfg_path, ckpt_path):
    from openvoice import utils
    from openvoice.models import SynthesizerTrn

    hps = utils.get_hparams_from_file(cfg_path)
    model = SynthesizerTrn(
        len(getattr(hps, "symbols", [])),
        hps.data.filter_length // 2 + 1,
        n_speakers=hps.data.n_speakers,
        **hps.model,
    )
    state = torch.load(ckpt_path, map_location="cpu", weights_only=False)
    model.load_state_dict(state["model"], strict=False)
    model.eval()
    return model, hps


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
    os.makedirs(ONNX_DIR, exist_ok=True)
    cfg, ckpt = find_converter()
    print(f"converter: {ckpt}")
    model, hps = load_model(cfg, ckpt)

    spec_ch = hps.data.filter_length // 2 + 1
    gin = int(hps.model.gin_channels)
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

    # ---- voice_conversion: spec, lengths, src_se, tgt_se -> audio ----
    strip_weight_norm(model)
    tau = 0.3

    class Converter(torch.nn.Module):
        def __init__(self, m, tau):
            super().__init__()
            self.m = m
            self.tau = tau

        def forward(self, spec, lengths, src_se, tgt_se):
            return self.m.voice_conversion(spec, lengths, sid_src=src_se,
                                           sid_tgt=tgt_se, tau=self.tau)[0]

    frames = 160
    spec = torch.randn(1, spec_ch, frames)
    lengths = torch.LongTensor([frames])
    src_se = torch.randn(1, gin, 1)
    tgt_se = torch.randn(1, gin, 1)
    torch.onnx.export(
        Converter(model, tau), (spec, lengths, src_se, tgt_se),
        os.path.join(ONNX_DIR, "voice_conversion.onnx"),
        input_names=["spec", "lengths", "src_se", "tgt_se"], output_names=["audio"],
        dynamic_axes={"spec": {2: "T"}, "audio": {2: "N"}}, opset_version=OPSET)
    print("exported voice_conversion.onnx")

    # ---- parity (PyTorch vs onnxruntime) + timing ----
    import onnxruntime as ort
    with torch.no_grad():
        ref_pt = RefEnc(model)(dummy_spec_t).numpy()
    ref_ox = ort.InferenceSession(os.path.join(ONNX_DIR, "ref_enc.onnx")) \
        .run(None, {"spec_t": dummy_spec_t.numpy()})[0]
    print(f"ref_enc max|Δ| = {np.abs(ref_pt - ref_ox).max():.2e}")

    t0 = time.time()
    with torch.no_grad():
        a_pt = Converter(model, tau)(spec, lengths, src_se, tgt_se).numpy()
    t_pt = time.time() - t0
    sess = ort.InferenceSession(os.path.join(ONNX_DIR, "voice_conversion.onnx"))
    t0 = time.time()
    a_ox = sess.run(None, {"spec": spec.numpy(), "lengths": lengths.numpy(),
                           "src_se": src_se.numpy(), "tgt_se": tgt_se.numpy()})[0]
    t_ox = time.time() - t0
    secs = frames * hps.data.hop_length / hps.data.sampling_rate
    print(f"voice_conversion max|Δ| = {np.abs(a_pt - a_ox).max():.2e}")
    print(f"timing ({frames} frames ≈ {secs:.1f}s audio): torch {t_pt:.2f}s, "
          f"onnx {t_ox:.2f}s  (A13 will be ~5–10× slower)")
    print("\nNEXT: base TTS export (V1) or move to V2/MeloTTS for production quality.")


if __name__ == "__main__":
    main()
