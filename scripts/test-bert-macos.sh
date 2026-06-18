#!/usr/bin/env bash
#
# Build + run the desktop ja_bert check: links onnxruntime + the synap_voice
# bridge + bert_check, runs the shipping build_ja_bert over the baked sentences
# and compares to MeloTTS's int8 ja_bert reference (proves the C++ BERT path).
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FW="${ROOT}/Frameworks/onnxruntime.xcframework/macos-arm64_x86_64"
ENGINE="${ROOT}/SynapLink/Core/Engine"
ONNX="${ROOT}/tools/openvoice/onnx"
ASSETS="${ROOT}/tools/openvoice/g2p_assets"
OUT_BIN="${ROOT}/build/bert-check"

mkdir -p "${ROOT}/build"
clang++ -std=c++17 -O1 -g \
    -I "${ENGINE}" \
    -F "${FW}" \
    -Xlinker -force_load -Xlinker "${FW}/onnxruntime.framework/onnxruntime" \
    -framework onnxruntime -framework Accelerate -framework Foundation -framework CoreML \
    "${ENGINE}/synap_voice.cpp" \
    "${ROOT}/tests/voice-smoke/bert_check.cpp" \
    -o "${OUT_BIN}"

exec "${OUT_BIN}" \
    "${ONNX}/melo_en.onnx" "${ONNX}/voice_conversion.onnx" "${ONNX}/bert_en_int8.onnx" \
    "${ASSETS}/bert_check.bin" "${ASSETS}"
