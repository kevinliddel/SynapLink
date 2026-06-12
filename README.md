# SynapLink

A fully offline, on-device multimodal chatbot for iOS. SwiftUI frontend, C++
inference core (llama.cpp + libmtmd), single omni model (audio + vision + text
input), streamed output, RAG, encrypted local chat history. No network calls
for inference — ever.

Baseline device: **iPhone 11 (A13, 4 GB RAM)**. 

## Architecture

```
┌──────────────────────────────────────────────────────────┐
│ SwiftUI (Chat UI, streaming bubbles, voice UI, settings) │
├──────────────────────────────────────────────────────────┤
│ Swift service layer                                      │
│  ChatSession · VoiceLoop (AVAudioEngine) · RAGService    │
│  ModelManager (download/verify/load) · MemoryGovernor    │
├──────────────────────────────────────────────────────────┤
│ C++ core (Swift⇄C++ interop or thin C shim)              │
│  InferenceEngine: llama.cpp + libmtmd                    │
│   - streaming token callback                             │
│   - mtmd tokenization of image/audio chunks              │
│   - prompt cache / KV reuse across turns                 │
│  Embedder: llama.cpp embedding context                   │
├──────────────────────────────────────────────────────────┤
│ Storage (all local, encrypted)                           │
│  SQLite (chats, messages, settings) — SQLCipher or       │
│  file-level NSFileProtectionComplete + Keychain keys     │
│  Vector store: sqlite-vec (or flat-file + brute force)   │
│  — corpus is small on-device)                            │
└──────────────────────────────────────────────────────────┘
```

## Layout

- `SynapLink/` — app sources (SwiftUI + Swift service layer + C/C++ engine)
- `scripts/build-llama-xcframework.sh` — builds `Frameworks/llama.xcframework`
  (Metal + libmtmd) from a pinned llama.cpp tag
- `scripts/test-engine-macos.sh` — desktop functional test of the engine core
- `docs/PHASE_0.md` — scaffolding & inference core: build + smoke-test instructions
- `docs/PHASE_1.md` — text chat MVP: architecture, model catalog, chat pipeline

## Quick start

```sh
scripts/build-llama-xcframework.sh   
open SynapLink.xcodeproj
```

See `docs/PHASE_0.md` for the on-device smoke test (exit gate: ≥7 tok/s,
peak footprint <1.8 GB on iPhone 11).
