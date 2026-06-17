#!/usr/bin/env bash
#
# Fetch the prebuilt onnxruntime iOS xcframework (the onnxruntime-c CocoaPods
# archive — the FULL build, all ops, which our VITS + converter graphs need).
# Building ONNX Runtime from source for iOS is a multi-hour ordeal, so unlike
# the llama/whisper/sd frameworks we pin a release and download it.
#
# Output: Frameworks/onnxruntime.xcframework  (static framework: linked, not embedded)
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${REPO_ROOT}/Frameworks"
BUILD_ROOT="${REPO_ROOT}/build/onnxruntime-dl"

# Bump deliberately; the URL host serves the onnxruntime-c pod archives.
ORT_VERSION="1.22.0"
ORT_URL="https://onnxruntimepackages.z14.web.core.windows.net/pod-archive-onnxruntime-c-${ORT_VERSION}.zip"

DEST="${OUT_DIR}/onnxruntime.xcframework"
if [ -d "${DEST}" ]; then
    echo "onnxruntime.xcframework already present — rm -rf it to refresh."
    exit 0
fi

mkdir -p "${BUILD_ROOT}" "${OUT_DIR}"
echo "Downloading onnxruntime-c ${ORT_VERSION}…"
curl -L --fail -o "${BUILD_ROOT}/ort.zip" "${ORT_URL}"
( cd "${BUILD_ROOT}" && unzip -q -o ort.zip )

if [ ! -d "${BUILD_ROOT}/onnxruntime.xcframework" ]; then
    echo "ERROR: onnxruntime.xcframework not found in the archive." >&2
    exit 1
fi
rm -rf "${DEST}"
mv "${BUILD_ROOT}/onnxruntime.xcframework" "${DEST}"
echo "Installed ${DEST} (onnxruntime ${ORT_VERSION})"
