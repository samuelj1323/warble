# AGENTS.md

## What this is
Warble builds a personalized speech-to-text model: fine-tuned open-weights Whisper on the owner's voice. Training runs on free cloud GPUs (Colab/Kaggle); recording and prep run locally on an Apple M1 with 8 GB RAM. Serving is a native macOS app, **WarbleMac** (SwiftUI + WhisperKit) — a voice harness for dictation, Mac-control commands, and Claude-Code-backed code changes reviewed in a Cursor-like diff panel. See `WarbleMac/README.md` for that app's own setup/run/test instructions.

## Environment
- macOS arm64, Apple M1, 8 GB unified memory — only whisper-tiny/base smoke tests locally; real training is for Colab.
- Python 3.13 venv at `.venv/` managed by **uv** (use `uv pip install --python .venv/bin/python ...`).
- `ffmpeg` (Homebrew) is required for audio decode/convert during training/prep.
- Run training scripts as `.venv/bin/python training/...` from the repo root.
- WarbleMac requires macOS 26+, Xcode 26+ (Swift 6); Mac-control agent mode requires Apple Intelligence / Foundation Models (macOS 26).

## Commands
- Recorder app: `.venv/bin/python recorder/app.py` → http://127.0.0.1:8000
- Build dataset: `.venv/bin/python training/prepare_dataset.py`
- Local smoke test: `.venv/bin/python training/train.py --model openai/whisper-tiny --epochs 1 --batch-size 4`
- Evaluate: `.venv/bin/python training/eval.py`
- Ad-hoc transcription: `.venv/bin/python training/transcribe.py <audio-file> [--model ...]`
- Convert checkpoint to CoreML (WhisperKit, one-time per checkpoint): see `WarbleMac/README.md`
- Run the app: `cd WarbleMac && swift run`
- Test the app: `cd WarbleMac && swift test`
- Merge feedback into training data: `.venv/bin/python training/prepare_dataset.py --include-feedback`

## Conventions
- Audio is always 16 kHz mono WAV; clips are capped at 30 s (Whisper's window).
- `data/raw/metadata.csv` (file_name,text) is the source of truth for the dataset; the recorder maintains it.
- Processed datasets store relative file names only — audio is resolved via `--data-dir` at train/eval time so the tree can move to Drive/Colab unchanged.
- `data/`, `models/`, `.venv/` are gitignored; never commit audio or checkpoints.
- WER is the primary metric, computed on lowercase/punctuation-stripped text (see `training/eval.py`).
- Training deps for Colab live in `requirements.txt`; local deps in `pyproject.toml` — keep them in sync.

## Architecture notes
- The recorder (port 8000, `recorder/app.py`) and `training/` are the only Python runtime pieces left; the old FastAPI backend (`server/app.py`), streaming/VAD (`server/streaming.py`), OpenRouter agent (`server/agent.py`, `server/tools.py`), and the Electron client (`electron/`) have been removed — fully replaced by the native `WarbleMac` app. `server/feedback.py` is kept only as the reference for `WarbleMac`'s native `FeedbackStore` schema (WAV + `metadata.csv` row format) — it isn't run anymore.
- `WarbleMac` (SwiftUI, Swift Package) runs the fine-tuned model on-device via WhisperKit (CoreML), replacing faster-whisper/CTranslate2 entirely. It has its own dictation core loop, global hotkey (⌘⇧D) + tray icon, and native paste-into-focused-app (`CGEvent`/`NSPasteboard`, replacing `@nut-tree-fork/nut-js`).
- Agent mode (toggle in the sidebar) classifies each finalized utterance on-device via Apple's Foundation Models framework (mac-control / code-change / chat) — no network call, replacing `server/agent.py`'s OpenRouter round-trip. Mac-control intents dispatch to native tool implementations matching the old `server/tools.py`'s behavior (open app/URL, volume, mute, lock screen, sleep display, screenshot, media control), then speak a confirmation via `TTSService` (`AVSpeechSynthesizer`).
- Code-change intents spawn a `claude --output-format stream-json` subprocess scoped to a configured repo root; the streamed transcript and proposed diff render live, and edits only reach disk via an explicit, UI-only **Apply** (never voice-triggered) — **Discard** drops them.
- Every transcription is still persisted by `WarbleMac`'s native `FeedbackStore` to `data/feedback/` (WAV + row in `metadata.csv`), byte-for-byte compatible with the old schema. `training/prepare_dataset.py --include-feedback` merges rows with a `corrected_text` or `rating == "correct"` into the next dataset build, copying their WAVs into `--data-dir` so file paths stay relative like recorder clips.

## Agent skills

### Issue tracker

Issues live as GitHub issues in `samuelj1323/warble` (via `gh`). See `docs/agents/issue-tracker.md`.

### Triage labels

Default five canonical roles, unchanged. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: `CONTEXT.md` + `docs/adr/` at the repo root. See `docs/agents/domain.md`.

## Roadmap
- The native Swift rewrite (`WarbleMac`) is built: dictation core loop + hotkey/paste/tray parity, TTS, on-device Mac-control agent mode, Claude-Code-backed code-change agent (multi-turn, view-only diff → Apply/Discard), and a Cursor-like sidebar/center layout tying it together.
- Possible next steps: surface feedback-driven WER improvements after a re-train; hands-free wake-word activation; more agent tools; packaging/signing/notarizing `WarbleMac` for distribution outside local `swift run`.
