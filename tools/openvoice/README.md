# OpenVoice on-device — prototype harness

Goal: clone a target voice (from a short reference clip / mp4) and use it for the
"read aloud" TTS, **fully on-device**, via OpenVoice + ONNX Runtime.

> **Status: SHIPPED.** This now runs in the app (read-aloud cloned voices on the
> 4 GB iPhone 11). See **[docs/VOICE_CLONING.md](../../docs/VOICE_CLONING.md)** for
> the shipped architecture and a step-by-step guide to **adding your own voice**.
> The phases below are the original de-risk plan, kept for historical context.

This folder began as the **Phase 0 desktop de-risk**: get OpenVoice running, clone
a voice, export the models to ONNX, and measure quality + speed before adding a
neural runtime to the iOS app. It now also holds the export/bake/validation
tooling the shipped feature is reproduced from.

## The pipeline (grounded in the OpenVoice source)

OpenVoice is not one model — for V1 (self-contained in the repo) it is:

1. **Base TTS** — `BaseSpeakerTTS.model.infer(x, x_lengths, sid, …)` → source speech
   (needs a text frontend: `openvoice/text/` cleaners + symbols).
   *V2 swaps this for MeloTTS — better quality + multilingual, but a separate
   port. We start with V1's base speaker to stay self-contained.*
2. **Reference encoder** — `ToneColorConverter.model.ref_enc(spec)` → a speaker
   embedding `g` from the reference clip (this is what "clones" the target).
3. **Tone-color converter** — `model.voice_conversion(spec, spec_lengths,
   sid_src, sid_tgt, tau)` → recolored audio in the target voice.

The **spectrogram** (`spectrogram_torch`, an STFT) is computed natively on-device
with Accelerate/vDSP — it is NOT exported; the ONNX graphs take the spectrogram
as input.

## ONNX export boundaries (what `export_onnx.py` produces)

| Model | Input | Output | Notes |
|---|---|---|---|
| `ref_enc.onnx` | spec `[B, T, spec_ch]` | `g [B, gin, 1]` | small, low risk |
| `voice_conversion.onnx` | spec, lengths, src_se, tgt_se, tau | audio `[B, 1, N]` | flow + HiFi-GAN decoder; **remove weight_norm before export**; main risk |
| `base_tts.onnx` | phoneme ids, lengths, sid | audio | V1 base; stochastic duration predictor — export caveats. V2 = MeloTTS instead |

## Phases

- **Phase 0 (here): desktop validation.** `setup.sh` → `export_onnx.py` →
  `clone_test.py`. Confirm: ONNX output matches PyTorch, judge quality, measure
  per-sentence latency on CPU (proxy for the A13, which will be slower).
- **Phase 1: runtime.** Add `onnxruntime.xcframework` to the app, mirroring the
  `llama/whisper/sd` xcframework + build-script pattern. A C/Swift bridge
  (`synap_voice`) that runs the three graphs.
- **Phase 2: text frontend.** Port `openvoice/text` (g2p/cleaners) to C/Swift, or
  compile espeak-ng. (V2/MeloTTS has a heavier frontend.)
- **Phase 3: integration.** Wire `SpeechReader` to the ONNX pipeline; extract +
  cache the target embedding from a reference clip once; unload the chat model
  while synthesizing (like image-gen).
- **Phase 4: UX.** Let the user pick/record the reference clip and manage the
  cloned voice in Settings.

## Reality check (iPhone 11 / A13 / 4 GB)

Neural TTS generates audio autoregressively/decoder-heavy — expect **seconds per
sentence**, slower than real-time, ~100–300 MB resident. A "tap, wait, listen"
feature, not instant. Phase 0's CPU timing tells us if that's acceptable before
we invest in Phases 1–4.

## Licensing

OpenVoice **V2** and MeloTTS are **MIT** (commercial use OK). V1 checkpoints were
non-commercial originally — verify the license of whatever checkpoint we ship.

## Run

```bash
cd tools/openvoice
./setup.sh                 # conda env (py3.11) + torch(CPU) + OpenVoice + V1 ckpts  (~2–3 GB, ~15–25 min)
conda run -n openvoice python export_onnx.py     # export the 3 graphs to ./onnx/
conda run -n openvoice python clone_test.py REF.wav "Hello there"   # end-to-end clone + ONNX-vs-PyTorch check
```

`vendor/`, `checkpoints/`, `onnx/`, `outputs/` are gitignored build artifacts.
