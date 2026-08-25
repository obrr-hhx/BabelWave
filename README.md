# BabelWave

Local, real-time bilingual subtitles for macOS. BabelWave is controlled from
the menu bar, captures system audio only, and performs both speech recognition
and translation locally.

## Current prototype

- SwiftUI `BW` menu bar controller, with no settings window or Dock icon.
- System-audio capture through ScreenCaptureKit; no video frames are consumed.
- Low-latency speech segmentation with pre-roll, 800 ms progressive snapshots,
  and 500 ms silence finalization.
- Qwen3-ASR 0.6B for multilingual speech recognition.
- Automatic source-language detection plus menu-bar overrides for Chinese,
  English, Japanese, and Korean; Japanese and Korean are translated to Chinese.
- Qwen3 1.7B Q8 for automatic Chinese ↔ English translation.
- One C++ inference process containing both persistent model contexts.
- One shared llama.cpp GGML/Metal backend; there is no external inference service.
- A SwiftUI lower-center bilingual subtitle panel using real behind-window blur.
- Background transparency is continuously adjustable from the menu bar and
  persists across launches without fading the subtitle text or controls.
- Move, resize, font-size, show/hide, lock, and reset-position controls.
- Long bilingual captions always stay in the user-sized window: the text wraps
  to as many lines as needed and automatically shrinks instead of paging,
  truncating, or resizing the panel.

The subtitle panel is locked by default, but its compact SF Symbols toolbar
always remains clickable. Click the pin in the panel before dragging its top
grip or lower-right resize handle. Its frame, font scale, lock state, and glass
transparency persist across launches.

The implementation reference for the current overlay is saved at
`Design/subtitle-overlay-concept.png`.

## Build and run

Requirements: Apple Silicon, macOS 14+, CMake, Clang, and the Xcode Command Line
Tools. Full Xcode is not required.

```bash
./scripts/build-app.sh
open build/BabelWave.app
```

The first capture asks for Screen Recording permission because that is the
macOS permission class used by ScreenCaptureKit. BabelWave registers only the
audio stream output.

## Models

BabelWave owns its model files directly under:

```text
~/Library/Application Support/BabelWave/models/
```

Install the ASR model converted from the official Qwen checkpoint:

```bash
./scripts/prepare-model.sh
```

Install the official Qwen3 1.7B Q8 translation GGUF:

```bash
./scripts/prepare-translation-model.sh
```

The translation download is checked against the official LFS SHA-256. No
model manager or external inference service is used at runtime.

## Latency-oriented inference design

- Both models are loaded once when `babelwaved` starts.
- ASR and translation exchange text in memory in the same process.
- One end-to-end request runs at a time because ASR and translation share the
  same Metal GPU. If inference falls behind, pending partials coalesce to the
  newest snapshot; revision ordering prevents an older result replacing a
  newer subtitle.
- The translation model offloads all layers and KQV operations to Metal.
- llama.cpp Flash Attention is forced on.
- The translation context is limited to 1536 tokens with a 512-token batch.
- Greedy decoding and `/no_think` avoid reasoning overhead.
- Translation failure degrades to source-language subtitles instead of
  blocking the capture pipeline.

## Local protocol

`babelwaved` binds only to `127.0.0.1:39173`.

```text
GET  /health
POST /v1/transcribe
```

`POST /v1/transcribe` accepts signed 16-bit little-endian mono PCM at 16 kHz.
Its JSON response contains the source text, translated text, source and target
languages, segment duration, ASR latency, and translation latency.
Set `X-BabelWave-Language` to `Chinese`, `English`, `Japanese`, or `Korean` to
use Qwen3-ASR's forced-language prompt instead of automatic detection.

## Prototype boundaries

- The current VAD is an energy gate rather than a neural VAD.
- Live partials are coalesced so inference cannot build an unbounded queue;
  segments finalize after 500 ms of silence or at 8 seconds.
- Qwen3-ASR is not a true streaming decoder. Captions never use future audio,
  but their measured delay still includes local ASR and translation time.
- Translation direction is Chinese-to-English; all other detected languages
  currently translate to Chinese.
- Qwen3 Forced Aligner is not wired into the live path yet.
- The app is ad-hoc signed for local development.
