#!/usr/bin/env bash
#
# Phase 0 desktop setup for the OpenVoice prototype. Creates a conda env (the
# system python is 3.14, which PyTorch has no wheels for), installs a CPU torch
# + OpenVoice + ONNX tooling, clones OpenVoice, and fetches the V1 checkpoints.
#
# Heavy: ~2–3 GB, ~15–25 min on a cold cache. Re-runnable (idempotent-ish).
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_NAME="openvoice"
VENDOR="${HERE}/vendor"
CKPT_DIR="${HERE}/checkpoints"
# The old S3 zips are 404; the checkpoints live on HuggingFace now. We only need
# the tone-color CONVERTER (ref_enc + voice_conversion) for the export — the V2
# converter is the same architecture as V1 and higher quality.
HF_CONVERTER="https://huggingface.co/myshell-ai/OpenVoiceV2/resolve/main/converter"

echo "== conda env (${ENV_NAME}, python 3.11) =="
if ! conda env list | grep -qE "^\s*${ENV_NAME}\s"; then
    conda create -y -n "${ENV_NAME}" python=3.11
fi

echo "== clone OpenVoice =="
mkdir -p "${VENDOR}"
if [ ! -d "${VENDOR}/OpenVoice" ]; then
    git clone --depth 1 https://github.com/myshell-ai/OpenVoice "${VENDOR}/OpenVoice"
fi

echo "== python deps (CPU torch + onnx) =="
# We load the converter directly from openvoice.models (pure torch+numpy), so we
# DON'T need librosa/numba/llvmlite (their source build was failing) or the text
# frontend. All of these have prebuilt cp311 macOS wheels.
conda run -n "${ENV_NAME}" python -m pip install --upgrade pip
conda run -n "${ENV_NAME}" python -m pip install \
    "torch" "torchaudio" --index-url https://download.pytorch.org/whl/cpu
# numpy<2: the CPU torch wheel's C-extension is built against NumPy 1.x, so
# NumPy 2 breaks tensor.numpy(). 1.26.x works (ignore OpenVoice's numpy==1.22 pin).
conda run -n "${ENV_NAME}" python -m pip install \
    "numpy<2" "onnx" "onnxruntime" "soundfile"
# Register the `openvoice` package WITHOUT its stale pinned deps (numpy==1.22 /
# librosa==0.9.1 have no py3.11 wheels and would re-trigger the llvmlite build).
conda run -n "${ENV_NAME}" python -m pip install --no-deps -e "${VENDOR}/OpenVoice"

echo "== checkpoints (V2 converter from HuggingFace) =="
mkdir -p "${CKPT_DIR}/converter"
if [ ! -f "${CKPT_DIR}/converter/checkpoint.pth" ]; then
    curl -L --fail -o "${CKPT_DIR}/converter/config.json" "${HF_CONVERTER}/config.json"
    curl -L --fail -o "${CKPT_DIR}/converter/checkpoint.pth" "${HF_CONVERTER}/checkpoint.pth"
fi

echo
echo "Done. Next:"
echo "  conda run -n ${ENV_NAME} python ${HERE}/export_onnx.py"
echo "  conda run -n ${ENV_NAME} python ${HERE}/clone_test.py <reference.wav> \"some text\""
