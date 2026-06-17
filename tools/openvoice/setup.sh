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
# V1 base-speaker + tone-color-converter checkpoints (self-contained).
CKPT_URL="https://myshell-public-repo-host.s3.amazonaws.com/openvoice/checkpoints_1226.zip"

echo "== conda env (${ENV_NAME}, python 3.11) =="
if ! conda env list | grep -qE "^\s*${ENV_NAME}\s"; then
    conda create -y -n "${ENV_NAME}" python=3.11
fi

echo "== clone OpenVoice =="
mkdir -p "${VENDOR}"
if [ ! -d "${VENDOR}/OpenVoice" ]; then
    git clone --depth 1 https://github.com/myshell-ai/OpenVoice "${VENDOR}/OpenVoice"
fi

echo "== python deps (CPU torch + onnx + openvoice) =="
# CPU-only torch keeps the download small and matches the dev Mac (Intel, no CUDA).
conda run -n "${ENV_NAME}" python -m pip install --upgrade pip
conda run -n "${ENV_NAME}" python -m pip install \
    "torch" "torchaudio" --index-url https://download.pytorch.org/whl/cpu
conda run -n "${ENV_NAME}" python -m pip install \
    "onnx" "onnxruntime" "librosa" "soundfile" "numpy" "scipy" "inflect" "unidecode"
# OpenVoice itself (pulls its own pinned deps; --no-deps if it fights torch).
conda run -n "${ENV_NAME}" python -m pip install -e "${VENDOR}/OpenVoice" || \
    conda run -n "${ENV_NAME}" python -m pip install --no-deps -e "${VENDOR}/OpenVoice"

echo "== checkpoints =="
mkdir -p "${CKPT_DIR}"
if [ ! -d "${CKPT_DIR}/checkpoints" ] && [ ! -d "${CKPT_DIR}/base_speakers" ]; then
    echo "Downloading V1 checkpoints…"
    curl -L --fail -o "${CKPT_DIR}/ckpt.zip" "${CKPT_URL}"
    ( cd "${CKPT_DIR}" && unzip -o ckpt.zip && rm -f ckpt.zip )
fi

echo
echo "Done. Next:"
echo "  conda run -n ${ENV_NAME} python ${HERE}/export_onnx.py"
echo "  conda run -n ${ENV_NAME} python ${HERE}/clone_test.py <reference.wav> \"some text\""
