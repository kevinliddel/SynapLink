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
for m in melo_en.onnx voice_conversion.onnx; do
  [ -f "${SRC}/${m}" ] || { echo "missing ${SRC}/${m} — run tools/openvoice exports" >&2; exit 1; }
  cp "${SRC}/${m}" "${DST}/${m}"
  echo "staged ${m}"
done
