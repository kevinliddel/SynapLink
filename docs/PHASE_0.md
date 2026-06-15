# Phase 0 — Scaffolding & Inference Core

Phase 0 checklist and how to run everything.

## What's here

| Piece | Location |
|---|---|
| llama.cpp pin (b9596, Gemma 4 mtmd vision+audio upstream) | git submodule at `third_party/llama.cpp`; `LLAMA_TAG` in the build script mirrors the pin and fails the build on drift |
| XCFramework build (Metal + libmtmd; iOS arm64, sim arm64+x86_64, macOS universal) | `scripts/build-llama-xcframework.sh` → `Frameworks/llama.xcframework` |
| C++ inference engine (load model+mmproj, streamed generate, cancel, KV prefix reuse, media eval) | `SynapLink/Core/Engine/synap_engine.{h,cpp}` |
| Swift interop (serialized engine owner, `AsyncThrowingStream` tokens) | `SynapLink/Core/Inference/InferenceEngine.swift` |
| Performance Test screen (tok/s + peak footprint vs exit gate; benchmarks installed Model Library models, Documents side-loads as extra sources) | `SynapLink/Presentation/Views/Debug/` |
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

## Performance test on device (exit gate)

1. Download a model in the **Model Library** (or side-load a GGUF into the
   app's Documents via Finder — side-loads appear as extra sources).
2. Settings → Diagnostics → **Performance Test** → Run. The model you chat
   with is preselected.
3. The verdict scores the exit gate directly:
   - **Decode ≥ 7 tok/s** ("Comfortable for daily use" and up)
   - **Peak memory < 1.8 GB** (gauge vs the ~2.1 GB system limit)
   - Also reported: first-word latency, load time, memory headroom, and the
     model's sample reply.

Engine parameters come from `RuntimeProfile` (device-RAM tiers; 4 GB =
ctx 1024 / 2 threads / q4_0 KV). Adjust there for sweeps.

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
  bump `LLAMA_TAG` **and** `LLAMA_COMMIT` in
  `scripts/build-llama-xcframework.sh` to match (the build fails if they
  drift from the checkout; the SHA is what's compared — shallow CI clones
  have no tags), rebuild, re-run `scripts/test-engine-macos.sh`, and commit
  the submodule bump together with the script change.
