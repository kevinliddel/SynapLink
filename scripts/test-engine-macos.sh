#!/usr/bin/env bash
#
# Builds and runs the desktop engine smoke test against the macOS slice of
# llama.xcframework. Validates the exact C++/C code the iOS app ships.
#
# Usage: scripts/test-engine-macos.sh <model.gguf> [mmproj.gguf]

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FW_DIR="${REPO_ROOT}/Frameworks/llama.xcframework/macos-arm64_x86_64"
OUT="${REPO_ROOT}/build/engine-smoke"

mkdir -p "${REPO_ROOT}/build"

clang++ -std=c++17 -O1 -g \
    -I "${REPO_ROOT}/SynapLink/Core/Engine" \
    -F "${FW_DIR}" \
    -framework llama \
    -rpath "${FW_DIR}" \
    "${REPO_ROOT}/SynapLink/Core/Engine/synap_engine.cpp" \
    "${REPO_ROOT}/tests/engine-smoke/main.cpp" \
    -o "${OUT}"

exec "${OUT}" "$@"
