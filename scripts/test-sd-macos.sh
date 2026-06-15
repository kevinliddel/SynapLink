#!/usr/bin/env bash
#
# Builds and runs the desktop image-generation smoke test against the macOS
# slice of sd.xcframework. Validates the synap_sd bridge the app ships.
#
# Usage: scripts/test-sd-macos.sh <model.gguf> "<prompt>" [size] [steps] [out.ppm]

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FW_DIR="${REPO_ROOT}/Frameworks/sd.xcframework/macos-arm64_x86_64"
OUT="${REPO_ROOT}/build/sd-smoke"

mkdir -p "${REPO_ROOT}/build"

clang++ -std=c++17 -O1 -g \
    -I "${REPO_ROOT}/SynapLink/Core/Engine" \
    -F "${FW_DIR}" \
    -framework sd \
    -rpath "${FW_DIR}" \
    "${REPO_ROOT}/SynapLink/Core/Engine/synap_sd.cpp" \
    "${REPO_ROOT}/tests/sd-smoke/main.cpp" \
    -o "${OUT}"

exec "${OUT}" "$@"
