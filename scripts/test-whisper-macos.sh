#!/usr/bin/env bash
#
# Builds and runs the desktop whisper smoke test against the macOS slice of
# whisper.xcframework. Validates the exact synap_whisper bridge the app ships.
#
# Usage: scripts/test-whisper-macos.sh <ggml-model.bin> <audio.wav> [expected-substr]

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FW_DIR="${REPO_ROOT}/Frameworks/whisper.xcframework/macos-arm64_x86_64"
OUT="${REPO_ROOT}/build/whisper-smoke"

mkdir -p "${REPO_ROOT}/build"

clang++ -std=c++17 -O1 -g \
    -I "${REPO_ROOT}/SynapLink/Core/Engine" \
    -F "${FW_DIR}" \
    -framework whisper \
    -rpath "${FW_DIR}" \
    "${REPO_ROOT}/SynapLink/Core/Engine/synap_whisper.cpp" \
    "${REPO_ROOT}/tests/whisper-smoke/main.cpp" \
    -o "${OUT}"

exec "${OUT}" "$@"
