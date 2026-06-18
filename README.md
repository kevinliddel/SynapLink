# SynapLink

A fully offline, on-device multimodal chatbot for iOS. SwiftUI frontend, C++
inference core (llama.cpp + libmtmd), single omni model (audio + vision + text
input), streamed output, RAG, encrypted local chat history. No network calls
for inference — ever.

Baseline device: **iPhone 11 (A13, 4 GB RAM)**. 

## Architecture

```mermaid
flowchart TB
    %% UI Layer
    subgraph UI["SwiftUI Layer"]
        UI1["Chat UI<br/>Streaming bubbles<br/>Voice UI / Settings"]
    end

    %% Service Layer
    subgraph Service["Swift Service Layer"]
        CS["ChatSession"]
        VL["VoiceLoop<br/>AVAudioEngine"]
        RAG["RAGService"]
        MM["ModelManager<br/>(download / verify / load)"]
        MG["MemoryGovernor"]
    end

    %% C++ Core
    subgraph Core["C++ Core"]
        IE["InferenceEngine<br/>llama.cpp + libmtmd"]
        EMB["Embedder<br/>llama.cpp embeddings"]

        IE --> D1["Streaming Tokens"]
        IE --> D2["Multimodal Tokenization"]
        IE --> D3["KV Cache / Prompt Reuse"]
    end

    %% Storage
    subgraph Storage["Local Encrypted Storage"]
        SQL["SQLite<br/>(chats / messages / settings)"]
        VEC["Vector Store<br/>sqlite-vec / flat file"]
        SEC["Encryption<br/>SQLCipher / NSFileProtection + Keychain"]
    end

    %% Flow
    UI1 --> CS
    UI1 --> VL

    CS --> RAG
    CS --> IE
    RAG --> EMB

    MM --> IE
    MG --> IE

    EMB --> VEC
    RAG --> SQL
    CS --> SQL

    SQL --> SEC
    VEC --> SEC

    %% Styles
    classDef ui fill:#f9fafb,stroke:#9ca3af,color:#111827
    classDef service fill:#eef2ff,stroke:#6366f1,color:#1e3a8a
    classDef core fill:#ecfdf5,stroke:#10b981,color:#065f46
    classDef storage fill:#fff7ed,stroke:#f59e0b,color:#7c2d12

    class UI1 ui
    class CS,VL,RAG,MM,MG service
    class IE,EMB core
    class SQL,VEC,SEC storage

    %% Data nodes
    classDef data fill:#0f172a,stroke:#334155,color:#94a3b8,font-size:11px
    class D1,D2,D3 data
```

## Layout

- `SynapLink/` — app sources (SwiftUI + Swift service layer + C/C++ engine)
- `scripts/build-frameworks.sh` — builds all three native xcframeworks (run this first)
- `scripts/build-{llama,whisper,sd}-xcframework.sh` — individual framework builds
  (llama.cpp + libmtmd, whisper.cpp ASR, stable-diffusion.cpp image-gen)
- `scripts/test-{engine,whisper,sd}-macos.sh` — desktop functional tests of the bridges
- `docs/PHASE_0.md` — scaffolding & inference core: build + smoke-test instructions
- `docs/PHASE_1.md` — text chat MVP: architecture, model catalog, chat pipeline
- `docs/PHASE_2.md` — multimodal input: attachments, capture, media validation
- `docs/PHASE_3.md` — sidecar specialists: whisper ASR, SmolVLM vision, SD image-gen

## Quick start

The `*.xcframework`s under `Frameworks/` are **gitignored build artifacts** —
you must build them before opening Xcode, or the build fails with
"There is no XCFramework found at …". One command does it (≈40–60 min first run;
each is skipped if already present):

```sh
git submodule update --init        # llama.cpp, whisper.cpp, stable-diffusion.cpp
scripts/build-frameworks.sh        # → Frameworks/{llama,whisper,sd}.xcframework
open SynapLink.xcodeproj
```

See `docs/PHASE_0.md` for the on-device smoke test (exit gate: ≥7 tok/s,
peak footprint <1.8 GB on iPhone 11).
