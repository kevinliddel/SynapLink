#!/usr/bin/env python3
"""
Export MeloTTS's English prosody BERT (bert-base-uncased) to ONNX for on-device
intonation. We only need hidden_states[-3] (the layer MeloTTS feeds into
ja_bert) -> [1, seq, 768]. Then int8-dynamic-quantize for the 4 GB device.

Also dumps bert_vocab.txt for the Swift WordPiece tokenizer.

Run with: KMP_DUPLICATE_LIB_OK=TRUE OMP_NUM_THREADS=1 TOKENIZERS_PARALLELISM=false
"""
import os

import numpy as np
import torch

HERE = os.path.dirname(os.path.abspath(__file__))
ONNX = os.path.join(HERE, "onnx")
ASSETS = os.path.join(HERE, "g2p_assets")
OPSET = 17
LOG = open("/tmp/bert_export_result.txt", "w")


def log(msg):
    LOG.write(msg + "\n")
    LOG.flush()


class BertWrap(torch.nn.Module):
    """Returns the single hidden layer MeloTTS uses (hidden_states[-3])."""

    def __init__(self, model):
        super().__init__()
        self.model = model

    def forward(self, input_ids, attention_mask, token_type_ids):
        out = self.model(input_ids=input_ids, attention_mask=attention_mask,
                         token_type_ids=token_type_ids, output_hidden_states=True)
        return out.hidden_states[-3]


def main():
    os.makedirs(ONNX, exist_ok=True)
    os.makedirs(ASSETS, exist_ok=True)
    from transformers import AutoTokenizer, AutoModelForMaskedLM

    model_id = "bert-base-uncased"
    tok = AutoTokenizer.from_pretrained(model_id)
    model = AutoModelForMaskedLM.from_pretrained(model_id).eval()
    wrap = BertWrap(model).eval()

    sample = tok("Hello there, this is a test of intonation.", return_tensors="pt")
    ids, mask, tt = sample["input_ids"], sample["attention_mask"], sample["token_type_ids"]

    fp32 = os.path.join(ONNX, "bert_en.onnx")
    torch.onnx.export(
        wrap, (ids, mask, tt), fp32,
        input_names=["input_ids", "attention_mask", "token_type_ids"],
        output_names=["hidden"],
        dynamic_axes={"input_ids": {1: "T"}, "attention_mask": {1: "T"},
                      "token_type_ids": {1: "T"}, "hidden": {1: "T"}},
        opset_version=OPSET)
    log(f"exported {fp32} ({os.path.getsize(fp32)/1e6:.0f} MB)")

    # parity: torch vs onnxruntime (deterministic — no RNG in BERT)
    import onnxruntime as ort
    with torch.no_grad():
        pt = wrap(ids, mask, tt).numpy()
    sess = ort.InferenceSession(fp32)
    feed = {"input_ids": ids.numpy(), "attention_mask": mask.numpy(),
            "token_type_ids": tt.numpy()}
    ox = sess.run(None, feed)[0]
    log(f"fp32 parity  shape={ox.shape}  max|d|={np.abs(pt - ox).max():.2e}")

    # int8 dynamic quantization (weights only) -> ~1/4 size. Pre-process when it
    # works (cleaner graph); BERT's symbolic shape inference is flaky, so fall
    # back to quantizing the raw export — dynamic quant doesn't require shapes.
    from onnxruntime.quantization import quantize_dynamic, QuantType
    int8 = os.path.join(ONNX, "bert_en_int8.onnx")
    src = fp32
    try:
        from onnxruntime.quantization.shape_inference import quant_pre_process
        prep = os.path.join(ONNX, "bert_en.prep.onnx")
        quant_pre_process(fp32, prep, skip_symbolic_shape=True)
        src = prep
    except Exception as exc:  # noqa: BLE001
        log(f"quant_pre_process skipped ({exc})")
    quantize_dynamic(src, int8, weight_type=QuantType.QInt8)
    if src != fp32 and os.path.exists(src):
        os.remove(src)
    log(f"quantized {int8} ({os.path.getsize(int8)/1e6:.0f} MB)")

    qsess = ort.InferenceSession(int8)
    qx = qsess.run(None, feed)[0]
    cos = float(np.dot(ox.ravel(), qx.ravel()) /
                (np.linalg.norm(ox.ravel()) * np.linalg.norm(qx.ravel())))
    log(f"int8 vs fp32  cos={cos:.5f}  max|d|={np.abs(ox - qx).max():.3f}")

    # vocab for the Swift WordPiece tokenizer (token per line, id == line index)
    vocab_path = os.path.join(ASSETS, "bert_vocab.txt")
    vocab = tok.get_vocab()
    inv = [None] * len(vocab)
    for token, idx in vocab.items():
        inv[idx] = token
    with open(vocab_path, "w", encoding="utf-8") as fh:
        fh.write("\n".join(inv))
    log(f"vocab {vocab_path} ({len(inv)} tokens)  "
        f"cls={tok.cls_token_id} sep={tok.sep_token_id} unk={tok.unk_token_id} pad={tok.pad_token_id}")


if __name__ == "__main__":
    main()
    LOG.close()
