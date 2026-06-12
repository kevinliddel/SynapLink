# Phase 2 — Multimodal Input (vision + audio)

Builds on [PHASE_1.md](PHASE_1.md). The capture UI (capability-driven input
bar, immersive voice recorder, HEIC→JPEG normalization) landed at the end of
Phase 1; this phase adds persistence, capture sources, latency affordances,
and the first real end-to-end validation of the engine's media path.

## What's here

- **Attachment persistence (encrypted):** media bytes live as files in
  `Application Support/private/attachments/` (`NSFileProtectionComplete`,
  no iCloud backup) with rows in a new `attachments` table (cascade-keyed to
  messages; files are removed when their message or chat is deleted).
  History renders real **image thumbnails** and an inline **voice-note
  player** (play/pause, duration) instead of text placeholders.
- **Regenerate works on media turns:** generation reads the last user
  message's attachments from the store, so a regenerated reply re-encodes
  the same photo/voice note.
- **Camera capture:** the camera button now offers Take Photo / Choose from
  Library (camera needs a real device; the dialog hides it where
  unavailable).
- **Encode-latency affordance:** media prefill takes seconds before the
  first token (image encode + chunk eval); the chat shows a pulsing
  "Analyzing…" bubble until tokens start (PLAN.md's "progress affordance").
- **E2E validation harness:** `tests/engine-smoke` accepts optional
  `[image] [audio]` args and runs real multimodal turns:

  ```sh
  scripts/test-engine-macos.sh build/models/gemma-4-E2B-it-Q4_K_M.gguf \
      build/models/mmproj-F16.gguf photo.jpg note.wav
  ```

  On Intel Macs (and `SYNAP_SMOKE_CPU=1`) the mmproj encoder is forced to
  CPU alongside the text model — CLIP-on-Metal needs an Apple-family GPU.

## Media format constraints (engine decoders)

| Input | Must be | Why |
|---|---|---|
| Images | JPEG/PNG/BMP/GIF, app sends JPEG ≤1024 px | stb_image (no HEIC) |
| Audio | WAV/MP3/FLAC, app records LPCM WAV @ model rate | miniaudio (no AAC) |

## Open items / decision gate

- **Device reality:** multimodal = E2B = **≥6 GB devices** (RAM-gated). The
  PLAN's Phase 2 decision gate ("is Gemma 4 audio on A13 good enough?") is
  overtaken by the harder constraint that E2B can't load on 4 GB at all.
  The 4 GB-tier fallback per PLAN §2 (split pipeline: ASR + small text
  model) remains undecided — needs a product call.
- **KV reuse across media turns** is still pending (the engine re-evaluates
  the full context on every media turn) — acceptable for photo Q&A, costly
  for long multimodal chats.
- **On-device latency numbers** (image encode + TTFT on an A16/A17-class
  ≥6 GB device) still need measuring against the ≤4 s target.
