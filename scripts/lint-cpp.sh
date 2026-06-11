#!/usr/bin/env bash
#
# Lints SynapLink's own C/C++ code (never third_party/):
#   1. clang-format --dry-run -Werror  (style, config in .clang-format)
#   2. cppcheck                        (static analysis, if installed)
#
# Usage: scripts/lint-cpp.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

FILES=(
    SynapLink/Core/Engine/synap_engine.h
    SynapLink/Core/Engine/synap_engine.cpp
    SynapLink/Core/Engine/synap_engine_internal.hpp
    SynapLink/Core/Engine/SynapLink-Bridging-Header.h
    tests/engine-smoke/main.cpp
)

echo "== clang-format =="
clang-format --dry-run -Werror "${FILES[@]}"
echo "clang-format: OK"

echo "== cppcheck =="
if command -v cppcheck > /dev/null; then
    # --inline-suppr lets justified suppressions live next to the code.
    # The engine headers include framework headers we don't analyze
    # (llama/mtmd), hence missingIncludeSystem is off by default anyway.
    cppcheck \
        --enable=warning,performance,portability \
        --inconclusive \
        --error-exitcode=1 \
        --inline-suppr \
        --suppress=unusedStructMember \
        --std=c++17 \
        --language=c++ \
        -I SynapLink/Core/Engine \
        "${FILES[@]}"
    echo "cppcheck: OK"
else
    echo "cppcheck not installed — skipping (brew install cppcheck)" >&2
fi
