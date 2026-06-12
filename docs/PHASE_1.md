# Phase 1 — Text Chat MVP

Architecture, decisions, and how to verify. Builds on [PHASE_0.md](PHASE_0.md).

## Clean architecture layout

Same layering as NeuraLink (`@Observable` singletons, no DI container):

```
SynapLink/
├── App/                    SynapLinkApp (routes --auto-benchmark → SmokeTest)
├── Domain/
│   ├── Entities/           Chat, Message (pure data)
│   └── Interfaces/         ChatRepositoryProtocol
├── Data/
│   ├── Repositories/       ChatStore (SQLite), ChatSettings (UserDefaults)
│   └── DataSources/
│       ├── Inference/      InferenceEngine (C bridge), ChatSession (orchestrator)
│       ├── ModelDownload/  ModelCatalog, ModelDownloadManager, HubCacheUtils
│       └── Database/       ChatDatabase (raw sqlite3 wrapper)
├── Core/
│   ├── Engine/             C/C++ inference core (Phase 0)
│   ├── Security/           ProtectedStorage
│   └── Utils/              MemoryFootprint
└── Presentation/
    ├── Views/              Chat/, ModelLibrary/, Settings/, Debug/
    └── Components/         MessageBubble, TypingIndicator
```

## Model download (NeuraLink approach)

- **Hugging Face `Hub` library** (swift-transformers ≥1.3, SPM): `HubApi.snapshot(from:matching:)`
  downloads ONLY the catalog files — unfiltered snapshots of GGUF repos would pull
  15+ quant variants (tens of GB). Integrity is verified by the Hub library against
  HF LFS metadata (this replaces PLAN.md's hand-rolled SHA256 step).
- Cache layout: `Application Support/hub/models--{org}--{repo}/snapshots/…`;
  resolution = persisted UserDefaults path (validated against the catalog filename,
  so a quant bump forces re-download) → Hub cache scan fallback.
- Pause/resume is task-level; the Hub library reuses completed parts on restart.
- Delete unloads the engine first (iOS only reclaims bytes when the last
  process unmaps the file).

### Catalog & the size problem

| Entry | Files | Size | Tier |
|---|---|---|---|
| Gemma 4 E2B (Q4_K_M) | unsloth/gemma-4-E2B-it-GGUF + mmproj-F16 | 4.1 GB | ≥6 GB devices |
| Gemma 4 E2B (Q4_0) | same repo, Q4_0 | 4.0 GB | ≥6 GB, older GPUs |
| Gemma 3 1B (Q4_K_M) | ggml-org/gemma-3-1b-it-GGUF | 0.8 GB | 4 GB (iPhone 11), text-only |

⚠️ **PLAN.md §1 budgeted ~1.3 GB for "E2B Q4" weights; the real files are ~3.1 GB**
(E2B = 5B raw parameters, 2B *active*). Whether E2B fits under the iPhone 11's
~2.1 GB jetsam limit is an open question for the on-device test — mmap +
per-layer-embedding streaming may keep the resident set far below file size, or
it may not. Gemma 3 1B is the guaranteed-fit fallback so the Phase 1 exit gate
(daily-driver chat on iPhone 11, no jetsam in 30 min) is testable either way.
Device-RAM default: <5 GB → Gemma 3 1B, otherwise E2B.

## Chat pipeline

1. `ChatSession.send()` persists the user turn, then rebuilds the full
   conversation: system prompt + sliding window of recent messages that fit
   `0.85 × (n_ctx − maxNewTokens)` (token estimate: 3.5 bytes/token + 10/message).
2. The model's **built-in chat template** formats the array (`llama_chat_apply_template`
   via the C bridge — no hand-rolled template strings). One exception: Gemma 4's
   `<|turn>role\n…<turn|>` format postdates llama.cpp b9596's template detector
   (it returns -1), so the engine carries a detection-based fallback
   (`apply_gemma4_template` in synap_engine.cpp) that triggers only when the
   model's embedded template contains `<|turn>`. Remove it once upstream
   llama.cpp learns the format (check `src/llama-chat.cpp` on the next pin bump).
3. The engine's longest-common-prefix prefill gives **KV reuse across turns**:
   only the new suffix is decoded each turn (verify via prefill stats in the
   smoke test: turn 2+ shows `reused > 0`).
4. Tokens stream into `streamingText`; the finished reply is persisted and the
   stream cleared. Stop = thread-safe engine cancel; regenerate = delete last
   assistant message + re-run.

## Storage

- `chats` / `messages` tables, raw sqlite3 (no GRDB/SwiftData), WAL mode,
  cascade delete, search via `LIKE` over titles + content.
- DB lives in `Application Support/private/` with `NSFileProtectionComplete`
  (+ journal/WAL siblings), excluded from iCloud backup. SQLCipher page-level
  encryption stays a Phase 5 opt-in, as in NeuraLink.

## Verify

```sh
swiftlint lint --strict && scripts/lint-cpp.sh   # lint
xcodebuild -project SynapLink.xcodeproj -scheme SynapLink \
  -destination 'generic/platform=iOS' build       # device build
scripts/simulator-smoketest.sh <model.gguf>       # CI-identical headless run
```

On-device exit gate: download a model from the Model Library, chat for 30
minutes — no jetsam, no stalls; Settings → Diagnostics → Smoke Test for tok/s.
