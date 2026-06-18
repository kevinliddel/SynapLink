#!/usr/bin/env bash
#
# Build + run the desktop voice-smoke test: links the macOS slice of
# onnxruntime.xcframework + the synap_voice bridge + the smoke main, runs the
# baked test chunks through the real pipeline, and writes a WAV.
#
# Usage: scripts/test-voice-macos.sh [out.wav] [target_se.f32]
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FW="${ROOT}/Frameworks/onnxruntime.xcframework/macos-arm64_x86_64"
ENGINE="${ROOT}/SynapLink/Core/Engine"
ASSETS="${ROOT}/tools/openvoice/assets"
ONNX="${ROOT}/tools/openvoice/onnx"
OUT_BIN="${ROOT}/build/voice-smoke"
OUT_WAV="${1:-${ROOT}/build/voice_smoke_riko.wav}"
TGT_SE="${2:-${ASSETS}/se_riko.f32}"

mkdir -p "${ROOT}/build"
clang++ -std=c++17 -O1 -g \
    -I "${ENGINE}" \
    -F "${FW}" \
    -Xlinker -force_load -Xlinker "${FW}/onnxruntime.framework/onnxruntime" \
    -framework onnxruntime -framework Accelerate -framework Foundation -framework CoreML \
    "${ENGINE}/synap_voice.cpp" \
    "${ROOT}/tests/voice-smoke/main.cpp" \
    -o "${OUT_BIN}"

exec "${OUT_BIN}" \
    "${ONNX}/melo_en.onnx" "${ONNX}/voice_conversion.onnx" \
    "${ASSETS}/test_chunks.bin" "${ASSETS}/se_source_en.f32" "${TGT_SE}" "${OUT_WAV}"
