# Phase 0 — Scaffolding & Inference Core

Phase 0 checklist and how to run everything.

## What's here

| Piece | Location |
|---|---|
| llama.cpp pin (b9596, Gemma 4 mtmd vision+audio upstream) | git submodule at `third_party/llama.cpp`; `LLAMA_TAG` in the build script mirrors the pin and fails the build on drift |
| XCFramework build (Metal + libmtmd; iOS arm64, sim arm64+x86_64, macOS universal) | `scripts/build-llama-xcframework.sh` → `Frameworks/llama.xcframework` |
| C++ inference engine (load model+mmproj, streamed generate, cancel, KV prefix reuse, media eval) | `SynapLink/Core/Engine/synap_engine.{h,cpp}` |
| Swift interop (serialized engine owner, `AsyncThrowingStream` tokens) | `SynapLink/Core/Inference/InferenceEngine.swift` |
| Smoke-test screen (tok/s + peak footprint vs exit gate) | `SynapLink/Features/SmokeTest/` |
| Desktop functional test (runs the same engine code on macOS) | `tests/engine-smoke/` + `scripts/test-engine-macos.sh` |

## Build steps

```sh
# 1. Build the framework (clones llama.cpp at the pinned tag on first run; ~30-50 min)
scripts/build-llama-xcframework.sh

# 2. Sanity-check the engine on the Mac with any small instruct GGUF
scripts/test-engine-macos.sh path/to/model.gguf [path/to/mmproj.gguf]

# 3. Build the app
xcodebuild -project SynapLink.xcodeproj -scheme SynapLink \
  -destination 'generic/platform=iOS' build
```

## Smoke test on iPhone 11 (exit gate)

1. Get a Gemma 4 E2B instruct GGUF (Q4_K_M) and its matching `mmproj-*.gguf`.
   Verify the SHA256 against the source repo before trusting the file.
2. Install the app on the phone, then copy both files into the app's
   **Documents** folder via Finder → iPhone → Files (file sharing is enabled).
3. Open the app → pick model (+ mmproj) → **Load Model** → **Run Benchmark**.
4. The results panel scores the exit gate directly:
   - **Decode ≥ 7 tok/s** (green check)
   - **Peak footprint < 1.8 GB** (green check)
   - Also reported: load time, TTFT, prefill tok/s, KV-reuse counts,
     minimum jetsam headroom (`os_proc_available_memory`).

Defaults match the PLAN budget: ctx 2048, q8_0 KV + flash attention, full
Metal offload, 4 threads. Adjust in `EngineParams.swift` for sweeps
(e.g. Q4_0 vs Q4_K_M weights, KV f16 vs q8_0, ctx 2048 vs 4096).

## Lint & CI

```sh
swiftlint lint --strict     # Swift (config: .swiftlint.yml, same rules as NeuraLink)
scripts/lint-cpp.sh         # C/C++: clang-format (.clang-format) + cppcheck
scripts/simulator-smoketest.sh <model.gguf>   # headless end-to-end run, CI-identical
```

`.github/workflows/CI.yaml` runs on push/PR to main:

1. **lint** — SwiftLint (strict) + clang-format + cppcheck.
2. **framework** — builds `llama.xcframework`, cached on the hash of the
   build script (so the ~40 min build only reruns when the llama.cpp pin or
   flags change).
3. **engine-test** — desktop engine smoke test against SmolLM2-135M
   (`SYNAP_SMOKE_CPU=1`: CI VMs have no usable Metal device).
4. **simulator-smoketest** — boots a simulator, injects the model, launches
   the app with `--auto-benchmark`, and asserts on the
   `benchmark-result.json` the app writes into Documents.

CI is functional-only; it never scores tok/s or memory. The Phase 0 exit
gate is scored exclusively on iPhone 11 hardware.

## Notes & deviations

- The dev Mac is **Intel**, so the simulator runs x86_64 (CPU inference only —
  fine for UI work, useless for performance numbers). All performance
  validation happens on device.
- `mtmd` media path re-evaluates the full context on every media turn;
  KV reuse across media turns is Phase 2 work.
- Model download/checksum UI is Phase 1 (`ModelManager`); Phase 0 side-loads
  via file sharing.
- llama.cpp upgrades: check out the new tag inside `third_party/llama.cpp`,
  bump `LLAMA_TAG` in `scripts/build-llama-xcframework.sh` to match (the build
  fails if they drift), rebuild, re-run `scripts/test-engine-macos.sh`, and
  commit the submodule bump together with the script change.
