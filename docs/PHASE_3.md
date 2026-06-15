# Phase 3 — Audio & Image for the 4 GB tier (sidecar specialists)

Builds on [PHASE_2.md](PHASE_2.md). The PLAN's Phase 3 is the realtime voice
loop; the prerequisite decided here is the **split-pipeline fallback** from
PLAN §2: since the omni Gemma 4 E2B can't fit on iPhone 11, dedicated small
models give the 4 GB tier real audio and image input, feeding a normal text
chat model.

## Architecture: sidecar specialists

```
        ┌─────────────── main chat model (e.g. Gemma 3 1B, text) ───────────────┐
 photo →│  VisionDescriber (SmolVLM-500M, own transient engine) → description ──→│→ reply
 voice →│  WhisperTranscriber (whisper.cpp base)              → transcript   ──→│
 text  →│ ─────────────────────────────────────────────────────────────────────│
        └────────────────────────────────────────────────────────────────────────┘
```

- **Audio = whisper.cpp** (`third_party/whisper.cpp`, pinned v1.8.6). A second
  ggml-based xcframework (`scripts/build-whisper-xcframework.sh` →
  `Frameworks/whisper.xcframework`). Two ggml frameworks coexist because each
  force-loads its **own** ggml and Apple's two-level namespace keeps the symbol
  sets private per dylib — verified: app links + runs with both. Bridge:
  `synap_whisper.{h,cpp}` → `WhisperTranscriber` (load → transcribe → unload).
- **Image = SmolVLM-500M** through the **existing mtmd vision path** (no new
  engine code). `VisionDescriber` runs it in its own transient `InferenceEngine`
  instance; the C llama backend is now **refcounted** (`backend_retain/release`)
  so the specialist engine and the main engine coexist.
- **Specialists load-use-unload**: only resident while working. Peak during an
  image turn ≈ main model + SmolVLM (~1.35 GB weights for the 1B + 500M combo),
  well under the iPhone 11 budget.

## Capability gating

The input bar's camera/voice buttons light up when the main model is natively
multimodal (E2B) **or** the matching specialist is installed
(`ChatSession.canSendImages / canSendAudio`). A turn's attachments route per
the main model's own capabilities: native (direct mtmd media, E2B) else sidecar
(`ChatSession.resolveMedia`). Image descriptions are injected as grounding
context; voice transcripts become the user's message text.

## Specialist catalog

| Specialist | Source | Files | Size |
|---|---|---|---|
| Speech to Text | ggerganov/whisper.cpp | ggml-base.bin | ~142 MB |
| Image Understanding | ggml-org/SmolVLM-500M-Instruct-GGUF | model + mmproj (Q8_0) | ~550 MB |

Downloaded via the same HF Hub mechanism (`SpecialistManager`), shown in the
Model Library under "Add-on capabilities".

## E2E validation (desktop, CPU)

```sh
scripts/test-whisper-macos.sh build/models/whisper/ggml-base.bin speech.wav fox
scripts/test-engine-macos.sh  smolvlm.gguf smolvlm-mmproj.gguf photo.jpg
```

Both passed: whisper transcribed `say`-generated speech verbatim; SmolVLM-500M
described a screenshot (image encode ~5 s on Intel CPU — vs E2B's ~87 s — and
30 tok/s decode). Device Metal will be markedly faster.

## Constraints (inherited)

- whisper wants mono float32 @ 16 kHz; `WhisperTranscriber` decodes any
  recording via `AVAudioConverter`. `VoiceRecorder` already captures mono WAV.
- SmolVLM images go through stb_image (JPEG; HEIC re-encoded as in Phase 2).
- The CLIP/mmproj encoder must run CPU on non-Apple GPUs (simulator) — handled
  by `RuntimeProfile.visionEngineParams` / `specialistUsesGPU`.

## Still open (the PLAN's realtime voice loop proper)

This phase delivered the **input models**; the streaming voice *loop* (VAD →
segment → transcribe → reply → **TTS out** → barge-in, ≤2.5 s budget) is the
next slice. TTS (PLAN §2) is not yet implemented — voice currently returns a
text reply, not spoken audio.
