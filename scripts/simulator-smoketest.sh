#!/usr/bin/env bash
#
# Headless simulator smoke test: builds the app, boots a simulator, injects a
# GGUF model into the app's Documents, launches with --auto-benchmark, and
# asserts on the benchmark-result.json the app writes when done.
#
# Functional gate only (does the full Swift→C→llama.cpp stack stream tokens?).
# Performance gates are scored on the iPhone 11, never in a simulator.
#
# Usage: scripts/simulator-smoketest.sh <model.gguf>
# Env:   SIM_DEVICE — simulator name (default: first available iPhone)

set -euo pipefail

MODEL="${1:?usage: scripts/simulator-smoketest.sh <model.gguf>}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

BUNDLE_ID="com.dedicatus.SynapLink"
DEVICE="${SIM_DEVICE:-$(xcrun simctl list devices available | grep -m1 -oE 'iPhone [^(]+' | sed 's/ *$//')}"
if [[ -z "${DEVICE}" ]]; then
    echo "FAIL: no available iPhone simulator found" >&2
    exit 1
fi
echo "== Simulator: ${DEVICE} =="

echo "== Building app =="
xcodebuild -project SynapLink.xcodeproj -scheme SynapLink \
    -destination "platform=iOS Simulator,name=${DEVICE}" \
    -configuration Debug \
    -derivedDataPath build/ci-derived \
    build CODE_SIGNING_ALLOWED=NO -quiet

APP="build/ci-derived/Build/Products/Debug-iphonesimulator/SynapLink.app"

echo "== Booting simulator =="
xcrun simctl boot "${DEVICE}" 2> /dev/null || true   # ok if already booted
xcrun simctl bootstatus "${DEVICE}" -b

echo "== Installing app + injecting model =="
xcrun simctl install "${DEVICE}" "${APP}"
CONTAINER="$(xcrun simctl get_app_container "${DEVICE}" "${BUNDLE_ID}" data)"
mkdir -p "${CONTAINER}/Documents"
cp "${MODEL}" "${CONTAINER}/Documents/"
rm -f "${CONTAINER}/Documents/benchmark-result.json"

echo "== Launching with --auto-benchmark =="
xcrun simctl terminate "${DEVICE}" "${BUNDLE_ID}" 2> /dev/null || true
xcrun simctl launch "${DEVICE}" "${BUNDLE_ID}" --auto-benchmark

RESULT="${CONTAINER}/Documents/benchmark-result.json"
echo "== Waiting for ${RESULT} (max 15 min) =="
for _ in $(seq 1 180); do
    [[ -f "${RESULT}" ]] && break
    sleep 5
done

if [[ ! -f "${RESULT}" ]]; then
    echo "FAIL: benchmark result never appeared (app crashed or hung?)" >&2
    xcrun simctl spawn "${DEVICE}" log show --last 5m \
        --predicate 'processImagePath contains "SynapLink"' 2> /dev/null | tail -50 || true
    exit 1
fi

cat "${RESULT}"
python3 - "${RESULT}" << 'EOF'
import json, sys
d = json.load(open(sys.argv[1]))
ok = d.get("status") == "ok" and d.get("decodeTokens", 0) > 0
print(f"\nstatus={d.get('status')} decodeTokens={d.get('decodeTokens')} "
      f"tps={d.get('decodeTokensPerSecond', 0):.1f}")
sys.exit(0 if ok else 1)
EOF
echo "SIMULATOR SMOKE TEST: OK"
