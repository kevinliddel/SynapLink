# Voice cloning for read-aloud (on-device)

An extra phase, woven in around Phase 3. The "read aloud" button on an assistant
reply speaks it in one of several **cloned voices**, fully offline on the 4 GB
iPhone 11 — no network, no per-voice model. A voice is just a **~1 KB speaker
embedding**; adding your own is a few steps (see [Add your own voice](#add-your-own-voice)).

Built on **OpenVoice V2** + **MeloTTS**, exported to ONNX and run via
`onnxruntime`. Licensing: OpenVoice V2 and MeloTTS are **MIT** (commercial OK).

## What ships

```
text → G2P (Swift) ─┬─→ phones/tones/langs ─────────────┐
                    └─→ WordPiece ids + word2ph ──→ BERT ─┤ (ja_bert prosody)
                                                          ▼
                                       MeloTTS VITS (melo_en.onnx, 44.1 kHz)
                                                          │  sdp_ratio=0.2 (natural rhythm)
                                                 vDSP 2:1 resample → 22.05 kHz
                                                          │
                                                 vDSP STFT (spectrogram)
                                                          ▼
                              tone-color converter (voice_conversion.onnx)
                              recolors to the target speaker embedding (se_<voice>.f32)
                                                          ▼
                              22.05 kHz mono → pipelined AVAudioEngine playback
```

- **Each voice = a 256-float embedding** (`ref_enc` of a reference clip,
  `gin_channels=256`). The converter recolors generic TTS to that timbre, so the
  whole "identity" of a voice is the ~1 KB `se_<name>.f32` file.
- **Cross-lingual:** the reference clip can be any language; output is English
  TTS in that timbre.
- **Intonation:** the stochastic duration predictor (rhythm) + `bert-base-uncased`
  prosody fed into MeloTTS's `ja_bert` input (pitch/emphasis). See
  [PLAN.md](../PLAN.md) §2.
- **Playback:** text is split at **sentence** boundaries so MeloTTS+BERT get full
  context; each chunk's silence is trimmed both ends; a ~1.5 s prebuffer keeps the
  player ahead of synthesis (no gaps).

## Where things live

| Piece | Path |
|---|---|
| C bridge (ORT: melo + bert + converter, vDSP STFT/resample) | [SynapLink/Core/Engine/synap_voice.{h,cpp}](../SynapLink/Core/Engine/) |
| Synthesis + chunking + playback | [SynapLink/Data/DataSources/Audio/VoiceCloner.swift](../SynapLink/Data/DataSources/Audio/VoiceCloner.swift) |
| English G2P + WordPiece + word2ph | [SynapLink/Data/DataSources/Audio/G2P.swift](../SynapLink/Data/DataSources/Audio/G2P.swift) |
| Voice selection (the enum you edit) | [SynapLink/Data/Repositories/VoiceSettings.swift](../SynapLink/Data/Repositories/VoiceSettings.swift) |
| Read-aloud routing (cloned vs system) | [SynapLink/Data/DataSources/Audio/SpeechReader.swift](../SynapLink/Data/DataSources/Audio/SpeechReader.swift) |
| Settings picker | [SynapLink/Presentation/Views/Settings/SettingsView.swift](../SynapLink/Presentation/Views/Settings/SettingsView.swift) |
| Bundled assets | [SynapLink/Resources/Voice/](../SynapLink/Resources/Voice/) |
| Desktop tooling (export / bake / validate) | [tools/openvoice/](../tools/openvoice/) |

**Bundled assets** — committed (tiny): `se_<voice>.f32`, `se_source_en.f32`,
`g2p_symbols.txt`, `g2p_meta.json`, `bert_vocab.txt`, `test_chunks.json`.
Staged + gitignored (large, reproduce via the export scripts +
`scripts/stage-voice-models.sh`): `melo_en.onnx` (163 MB), `voice_conversion.onnx`
(122 MB), `bert_en.onnx` (95 MB, int8), `g2p_lexicon.txt` (4.6 MB).

## Add your own voice

You only need the desktop tooling for **step 2** (baking the embedding); the rest
is a tiny committed file + a one-line enum case.

**Prerequisite (one-time):** set up the desktop env and converter checkpoint —
`tools/openvoice/setup.sh` then `setup_melotts.sh` (conda `openvoice`, py3.11;
see [tools/openvoice/README.md](../tools/openvoice/README.md)).

### 1. Get a clean reference clip
- **10–40 s** of clear speech from the target voice, expressive but not shouting.
- **Clean vocals are everything** — the embedding bakes in *whatever* is in the
  clip, including background music/noise, and the converter faithfully reproduces
  it. If the source has instruments/ambiance, **vocal-separate it first**
  (Demucs / UVR / Spleeter) — that beats denoising, which muffles the voice. (This
  is exactly how `touma`/`ayanokoji` were cleaned.)
- Drop it at `tools/openvoice/voices/<name>.{wav,mp3}` (e.g. `voices/nova.wav`).

### 2. Bake the embedding
Add `<name>` to the `VOICES` map in
[tools/openvoice/rebake_se.py](../tools/openvoice/rebake_se.py) (leave it out of
`NOISY` — that's only for clips you couldn't vocal-separate and want ffmpeg to
denoise), then:

```bash
cd tools/openvoice
KMP_DUPLICATE_LIB_OK=TRUE OMP_NUM_THREADS=1 TOKENIZERS_PARALLELISM=false \
  conda run -n openvoice python rebake_se.py
  
# → tools/openvoice/assets/se_<name>.f32   (256 floats, ~1 KB)
```

The bake is deterministic (afconvert resample → `ref_enc`); re-running yields an
identical embedding, and existing voices are untouched (cosine 1.0).

### 3. Ship the embedding
```bash
cp tools/openvoice/assets/se_<name>.f32 SynapLink/Resources/Voice/se_<name>.f32
```
This ~1 KB file **is committed** (it's not matched by the `*.onnx` / lexicon
gitignore rules). No model staging needed.

### 4. Register the voice in the app
Add a case to `ReadAloudVoice` in
[VoiceSettings.swift](../SynapLink/Data/Repositories/VoiceSettings.swift). The
`rawValue` **must** match the embedding filename: `se_<rawValue>.f32`
(`embeddingResource` derives it automatically).

```swift
enum ReadAloudVoice: String, CaseIterable, Identifiable {
    case system, riko, akira, touma, ayanokoji, nova   // ← add `nova`

    var label: String {
        switch self {
        ...
        case .nova: return "Nova"                      // ← display name
        }
    }
    var gender: String? {
        switch self {
        ...
        case .riko, .akira, .nova: return "Female"     // ← optional F/M tag
        case .touma, .ayanokoji: return "Male"
        }
    }
    // isCloned / embeddingResource need no change — they cover all non-.system cases.
}
```

### 5. Build & test
Build and run. The new voice appears in **Settings ▸ Voice**. Select it, then tap
the speaker on any assistant reply — the cloned voice (with the model load on
first use) reads it aloud. `VoiceCloner.isAvailable` gates the cloned options on
the ONNX models being bundled, so the picker degrades to **System** if they're
absent.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| Background noise / music in the output | Reference clip wasn't clean → **vocal-separate** it and re-bake (step 1–3). |
| Flat / robotic intonation | Ensure `bert_en.onnx` is staged (`stage-voice-models.sh`) and melo was exported with `sdp_ratio=0.2`. |
| Rare/technical words mispronounced | G2P is lexicon-only (129 k words); out-of-vocab falls back to per-char. Bigger lexicon / an OOV LSTM is a known future improvement. |
| Voice doesn't appear in Settings | Embedding filename ≠ `se_<rawValue>.f32`, or the ONNX models aren't bundled (`isAvailable == false`). |
| Long gap between paragraphs | Synthesis fell below real-time on device; the prebuffer cushion masks variance but not a sustained deficit — reduce per-chunk cost. |

## Reproducing the bundled models

```bash
scripts/build-onnxruntime-xcframework.sh          # ORT static xcframework (download)
cd tools/openvoice
conda run -n openvoice python export_melo_onnx.py # melo_en.onnx (VITS, sdp_ratio=0.2)
conda run -n openvoice python export_onnx.py      # voice_conversion.onnx (tone-color converter)
conda run -n openvoice python export_bert_onnx.py # bert_en.onnx (int8) + bert_vocab.txt
conda run -n openvoice python dump_g2p_assets.py  # g2p_lexicon/symbols/meta
cd ../.. && scripts/stage-voice-models.sh         # copy the large models into Resources/Voice
```

Validation harnesses: `tools/openvoice/test_g2p.swift` (G2P vs MeloTTS, byte-exact),
`scripts/test-bert-macos.sh` (C++ `ja_bert` vs reference), `scripts/test-voice-macos.sh`
(end-to-end bridge → WAV).
