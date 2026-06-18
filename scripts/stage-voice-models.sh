#!/usr/bin/env bash
# Copy the exported voice ONNX models into the app bundle resources. They're
# large + gitignored (reproduce via tools/openvoice/export_*.py), staged here
# like the xcframeworks. The tiny .f32 embeddings + test_chunks.json ARE committed.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${ROOT}/tools/openvoice/onnx"
DST="${ROOT}/SynapLink/Resources/Voice"
mkdir -p "${DST}"
cp "${ROOT}/tools/openvoice/g2p_assets/lexicon.txt" "${DST}/g2p_lexicon.txt" && echo "staged g2p_lexicon.txt"
cp "${ROOT}/tools/openvoice/g2p_assets/bert_vocab.txt" "${DST}/bert_vocab.txt" && echo "staged bert_vocab.txt"
for m in melo_en.onnx voice_conversion.onnx; do
  [ -f "${SRC}/${m}" ] || { echo "missing ${SRC}/${m} — run tools/openvoice exports" >&2; exit 1; }
  cp "${SRC}/${m}" "${DST}/${m}"
  echo "staged ${m}"
done
# Prosody BERT (int8) -> bert_en.onnx. Optional: absent => intonation disabled.
if [ -f "${SRC}/bert_en_int8.onnx" ]; then
  cp "${SRC}/bert_en_int8.onnx" "${DST}/bert_en.onnx"
  echo "staged bert_en.onnx (int8)"
else
  echo "note: ${SRC}/bert_en_int8.onnx absent — run export_bert_onnx.py for intonation" >&2
fi
