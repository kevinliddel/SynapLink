#!/usr/bin/env python3
"""
Validate the on-device BERT-prosody pipeline against MeloTTS and dump refs for
the Swift port. For each (in-vocab) sentence:

  1. melo clean_text -> norm_text, phones, tones, word2ph  (+ add_blank doubling)
  2. ja_bert from our exported bert onnx (fp32 AND int8) via hidden[-3] repeated
     by word2ph -> [768, T];  compare to MeloTTS's own torch ja_bert (correctness)
  3. melo.infer audio with ja_bert in {zero, fp32, int8} under a fixed seed
     -> does BERT change prosody (zero vs fp32)?  is int8 ~ fp32?  (quant decision)
  4. write refs (input_ids, word2ph, phones/tones/langs, ja_bert_fp32) for Swift.

Run with: KMP_DUPLICATE_LIB_OK=TRUE OMP_NUM_THREADS=1 TOKENIZERS_PARALLELISM=false
"""
import json
import os

import numpy as np
import onnxruntime as ort
import torch

HERE = os.path.dirname(os.path.abspath(__file__))
ONNX = os.path.join(HERE, "onnx")
ASSETS = os.path.join(HERE, "g2p_assets")
LOG = open("/tmp/bert_refs_result.txt", "w")

SENTENCES = [
    "Hello, world!",
    "The answer is forty two.",
    "Sure! Here is what I think about that.",
    "How are you doing today?",
    "Please tell me more about that, and I will help.",
]


def log(m):
    LOG.write(m + "\n")
    LOG.flush()


def cos(a, b):
    a, b = a.ravel(), b.ravel()
    n = min(a.size, b.size)
    a, b = a[:n], b[:n]
    return float(np.dot(a, b) / (np.linalg.norm(a) * np.linalg.norm(b) + 1e-9))


def main():
    from melo.api import TTS
    from melo.text.cleaner import clean_text
    from melo.text import cleaned_text_to_sequence
    from melo import commons
    from melo.text import english_bert

    tts = TTS(language="EN", device="cpu")
    net = tts.model.eval()
    sid = torch.LongTensor([tts.hps.data.spk2id["EN-US"]])
    tok = english_bert.tokenizer

    fp32 = ort.InferenceSession(os.path.join(ONNX, "bert_en.onnx"))
    int8 = ort.InferenceSession(os.path.join(ONNX, "bert_en_int8.onnx"))

    def ja_bert_from(sess, input_ids, word2ph_doubled):
        feed = {"input_ids": input_ids[None].astype(np.int64),
                "attention_mask": np.ones_like(input_ids)[None].astype(np.int64),
                "token_type_ids": np.zeros_like(input_ids)[None].astype(np.int64)}
        hidden = sess.run(None, feed)[0][0]            # [seq, 768]
        rows = [np.repeat(hidden[i][None], word2ph_doubled[i], axis=0)
                for i in range(len(word2ph_doubled))]
        return np.concatenate(rows, axis=0).T          # [768, T]

    def synth(phones, tones, langs, ja_bert):
        torch.manual_seed(0)
        x = torch.LongTensor(phones)[None]
        with torch.no_grad():
            audio = net.infer(
                x, torch.LongTensor([len(phones)]), sid,
                torch.LongTensor(tones)[None], torch.LongTensor(langs)[None],
                torch.zeros(1, 1024, len(phones)),
                torch.FloatTensor(ja_bert)[None],
                noise_scale=0.6, length_scale=1.0, noise_scale_w=0.8, sdp_ratio=0.0)[0]
        return audio[0, 0].cpu().numpy()

    refs = []
    for si, text in enumerate(SENTENCES):
        norm, phones_s, tones_s, word2ph = clean_text(text, "EN")
        phones, tones, langs = cleaned_text_to_sequence(phones_s, tones_s, "EN", tts.symbol_to_id)
        # add_blank: intersperse 0 + double word2ph (+1 on first for the leading blank)
        phones = commons.intersperse(phones, 0)
        tones = commons.intersperse(tones, 0)
        langs = commons.intersperse(langs, 0)
        w2p = [w * 2 for w in word2ph]
        w2p[0] += 1

        input_ids = tok(norm, return_tensors="np")["input_ids"][0].astype(np.int64)
        assert len(input_ids) == len(w2p), (len(input_ids), len(w2p))

        jb_fp32 = ja_bert_from(fp32, input_ids, w2p)
        jb_int8 = ja_bert_from(int8, input_ids, w2p)
        assert jb_fp32.shape[1] == len(phones), (jb_fp32.shape, len(phones))

        # MeloTTS's own ja_bert (torch path) — correctness reference
        _, ref_jb, ref_ph, ref_tn, ref_ln = \
            __import__("melo.utils", fromlist=["get_text_for_tts_infer"]).get_text_for_tts_infer(
                text, "EN", tts.hps, "cpu", tts.symbol_to_id)
        ref_jb = ref_jb.cpu().numpy()

        a_zero = synth(phones, tones, langs, np.zeros_like(jb_fp32))
        a_fp32 = synth(phones, tones, langs, jb_fp32)
        a_int8 = synth(phones, tones, langs, jb_int8)

        log(f"[{si}] \"{text}\"  phones={len(phones)} ids={len(input_ids)}")
        log(f"     ja_bert onnx-fp32 vs melo-torch  cos={cos(jb_fp32, ref_jb):.5f}  "
            f"(phones match melo: {list(map(int, phones)) == list(map(int, ref_ph))})")
        log(f"     ja_bert int8 vs fp32             cos={cos(jb_int8, jb_fp32):.5f}")
        log(f"     AUDIO bert(fp32) vs no-bert      cos={cos(a_fp32, a_zero):.4f}  "
            f"len {len(a_zero)}->{len(a_fp32)}   (low cos = bert changes prosody)")
        log(f"     AUDIO int8 vs fp32               cos={cos(a_int8, a_fp32):.4f}  "
            f"len {len(a_fp32)}->{len(a_int8)}   (high cos = int8 safe)")

        jb_fp32.astype(np.float32).tofile(os.path.join(ASSETS, f"bert_ref_{si}.f32"))
        jb_int8.astype(np.float32).tofile(os.path.join(ASSETS, f"bert_ref_int8_{si}.f32"))
        refs.append({
            "text": text, "norm_text": norm,
            "input_ids": [int(v) for v in input_ids],
            "word2ph_doubled": [int(v) for v in w2p],
            "phones": [int(v) for v in phones],
            "tones": [int(v) for v in tones],
            "langs": [int(v) for v in langs],
            "ja_bert_shape": [int(jb_fp32.shape[0]), int(jb_fp32.shape[1])],
            "ja_bert_file": f"bert_ref_{si}.f32",
        })

    with open(os.path.join(ASSETS, "bert_refs.json"), "w") as fh:
        json.dump(refs, fh, indent=2)

    # Binary for the C++ build_ja_bert check: count, then per sentence
    # int32 n_ids, int32 n, int64[n_ids] input_ids, int32[n_ids] word2ph.
    with open(os.path.join(ASSETS, "bert_check.bin"), "wb") as fh:
        fh.write(np.int32(len(refs)).tobytes())
        for r in refs:
            ids = np.asarray(r["input_ids"], dtype=np.int64)
            w2p = np.asarray(r["word2ph_doubled"], dtype=np.int32)
            fh.write(np.int32(len(ids)).tobytes())
            fh.write(np.int32(r["ja_bert_shape"][1]).tobytes())
            fh.write(ids.tobytes())
            fh.write(w2p.tobytes())
    log(f"\nwrote {len(refs)} refs -> bert_refs.json + bert_ref_*.f32 + bert_ref_int8_*.f32 + bert_check.bin")


if __name__ == "__main__":
    main()
    LOG.close()
