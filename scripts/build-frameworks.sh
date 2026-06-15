#!/usr/bin/env bash
#
# Builds ALL native xcframeworks SynapLink needs, in order. Run this once after
# cloning (and after any submodule pin bump) BEFORE opening Xcode — the
# frameworks are gitignored build artifacts, so without them Xcode fails with
# "There is no XCFramework found at .../Frameworks/<name>.xcframework".
#
#   llama.xcframework    — text + multimodal inference core (llama.cpp + libmtmd)
#   whisper.xcframework  — speech-to-text specialist (whisper.cpp)
#   sd.xcframework       — experimental image generation (stable-diffusion.cpp)
#
# Each sub-build is skipped if its framework already exists; pass --force to
# rebuild everything.
#
# Usage: scripts/build-frameworks.sh [--force]

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FORCE="${1:-}"

build_one() {
    local name=$1 script=$2
    if [[ "${FORCE}" != "--force" && -d "${REPO_ROOT}/Frameworks/${name}.xcframework" ]]; then
        echo "✓ ${name}.xcframework already built (use --force to rebuild)"
        return
    fi
    echo "== Building ${name}.xcframework =="
    "${REPO_ROOT}/scripts/${script}"
}

build_one llama   build-llama-xcframework.sh
build_one whisper build-whisper-xcframework.sh
build_one sd      build-sd-xcframework.sh

echo ""
echo "All frameworks ready in Frameworks/. You can now build SynapLink in Xcode."
