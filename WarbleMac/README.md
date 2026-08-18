# WarbleMac

Native macOS Swift app — the target of the [Swift rewrite](../AGENTS.md). Built as a Swift Package (SwiftUI `App` executable target), not a hand-built `.xcodeproj`.

## Requirements

- macOS 26+, Xcode 26+ (Swift 6).
- The fine-tuned checkpoint already produced by the training pipeline at `models/whisper-warble/final` (see the root `README.md`).

## Run

```
cd WarbleMac
swift run
```

This opens a window and, on launch, tries to load a converted CoreML model bundle from `models/whisper-warble-coreml` (relative to the current working directory — run from the repo root, or override with `WARBLE_MODEL_PATH=/path/to/bundle swift run`). It prints the loaded model's name and size, or an error if the bundle isn't there yet.

Once the model loads, hold the "Hold to talk" button and speak; releasing it (or ~0.7s of trailing silence) finalizes the utterance and transcribes it via WhisperKit, showing the text in the window.

You can also dictate from anywhere: press **⌘⇧D** to start recording regardless of which app is focused, and press it again (or wait for trailing silence) to finalize. The transcribed text is pasted into whichever app currently has focus via a simulated Cmd+V, same as the old Electron app's `nut-js`-based paste. A menu-bar icon shows the current state (🎙️ idle, 🔴 recording, ⏳ transcribing).

Pasting into other apps requires **Accessibility permission** for this app (System Settings → Privacy & Security → Accessibility) — on first launch without it granted, a prompt appears and a message is printed to the console; the app keeps working for in-window dictation either way.

Each finalized utterance is also logged to `data/feedback/` (relative to the working directory) as a 16 kHz WAV plus a row in `data/feedback/metadata.csv`, using the exact same schema as the old Python server's `FeedbackStore` — so `training/prepare_dataset.py --include-feedback` keeps working unchanged.

A "Test TTS" button plays a spoken confirmation via `TTSService` (`AVSpeechSynthesizer`, fully offline) — a temporary manual-verification hook for the standalone TTS service, ahead of it being wired into the Mac-control and code-change agent flows in later tickets.

Flip the **Agent mode** toggle to route finalized utterances to the on-device agent router instead of pasting them. The router classifies the transcript using Apple's on-device Foundation Models framework (mac-control / code-change / chat) — no network call, replacing the old Python server's OpenRouter-backed `agent.py`. Mac-control intents (open an app, open a URL, set volume/mute, lock the screen, sleep the display, take a screenshot, control media playback) dispatch to native tool implementations matching `server/tools.py`'s behavior, then speak a confirmation via `TTSService`. Code-change intents currently return a stub reply (real handling lands in later tickets); chat intents get a short spoken reply. Agent mode requires macOS 26 (Apple Intelligence / Foundation Models).

## Test

```
cd WarbleMac
swift test
```

## One-time setup: convert the fine-tuned checkpoint to CoreML

WhisperKit doesn't do model conversion itself — that's a separate step using Argmax's [`whisperkittools`](https://github.com/argmaxinc/whisperkittools) Python package, run once per checkpoint (mirrors the `ct2-transformers-converter` step in the root `README.md` for the old CTranslate2 server).

```
# in a Python env (the repo's .venv is fine)
uv pip install --python ../.venv/bin/python whisperkittools

../.venv/bin/python -m whisperkit.generate_model \
  --model-path ../models/whisper-warble/final \
  --output-dir ../models/whisper-warble-coreml
```

Check the `whisperkittools` README for the exact current CLI flags — this tool moves fast and flags have changed across releases. The important part is the output: a directory WhisperKit's `WhisperKitConfig(modelFolder:)` can load directly, i.e. what `WarbleMac` expects at `models/whisper-warble-coreml`.

`models/whisper-warble-coreml/` is gitignored, same as the rest of `models/` — never commit converted model weights.
