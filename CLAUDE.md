# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Warble builds a personalized speech-to-text model: fine-tuned open-weights Whisper on the owner's voice. Training runs on free cloud GPUs (Colab/Kaggle); recording and dataset prep run locally on an Apple M1 (8 GB RAM). Serving is a native macOS app, **WarbleMac** (SwiftUI + WhisperKit) — dictation, Mac-control voice commands, and Claude-Code-backed code changes reviewed in a Cursor-like diff panel.

Full details live in `AGENTS.md` (root) and `WarbleMac/README.md` — read those before making non-trivial changes; this file is the condensed version.

## Commands

Python side (`.venv/` managed by `uv`, run from repo root):
- Recorder app: `.venv/bin/python recorder/app.py` → http://127.0.0.1:8000
- Build dataset: `.venv/bin/python training/prepare_dataset.py` (add `--include-feedback` to merge corrected/approved feedback rows)
- Local smoke test train: `.venv/bin/python training/train.py --model openai/whisper-tiny --epochs 1 --batch-size 4`
- Evaluate: `.venv/bin/python training/eval.py`
- Ad-hoc transcription: `.venv/bin/python training/transcribe.py <audio-file> [--model ...]`
- Install/sync deps: `uv sync` (or `uv pip install --python .venv/bin/python ...` for one-offs)

WarbleMac (Swift Package, from `WarbleMac/`):
- Run: `swift run` (loads model from `models/whisper-warble-coreml` relative to CWD — run from repo root or set `WARBLE_MODEL_PATH`)
- Test all: `swift test`
- Test a single test: `swift test --filter <TestClassName>/<testMethodName>` (or just `<TestClassName>` for the whole class)
- Convert a fine-tuned checkpoint to CoreML (one-time per checkpoint, needs `whisperkittools`): see `WarbleMac/README.md` §"One-time setup"

Requires macOS 26+, Xcode 26+ (Swift 6); agent mode needs Apple Intelligence / Foundation Models.

## Architecture

**Python pipeline (training only, not runtime):**
- `recorder/app.py` — FastAPI + vanilla JS local web app; records 16 kHz mono WAV clips, maintains `data/raw/metadata.csv` (file_name,text) as dataset source of truth.
- `training/prepare_dataset.py` → `train.py` → `eval.py` — validate/split clips, fine-tune (local smoke test or Colab via `finetune.ipynb`), report WER (stock vs fine-tuned; lowercase/punctuation-stripped).
- `server/feedback.py` is dead code kept only as a schema reference for WarbleMac's native `FeedbackStore` — do not run it. The old FastAPI backend, streaming/VAD, OpenRouter agent, and Electron client have all been removed; WarbleMac fully replaces them.
- Clips are capped at 30 s (Whisper's window). Processed datasets store relative file names only; audio is resolved via `--data-dir` at train/eval time so the tree can move to Drive/Colab unchanged. `data/`, `models/`, `.venv/` are gitignored — never commit audio or checkpoints.

**WarbleMac (Swift Package, SwiftUI, the actual runtime app)** — `WarbleMac/Sources/WarbleMac/`:
- `WhisperModelLoader` — loads the converted CoreML bundle via WhisperKit.
- `UtteranceSegmenter` + `HotkeyManager` / `PushToTalkController` — dictation core loop: hold-to-talk in-window, or global ⌘⇧D hotkey from anywhere; finalizes on release or ~0.7s trailing silence.
- `PasteService` — native paste into the focused app via `CGEvent`/`NSPasteboard` (simulated Cmd+V), requires Accessibility permission.
- `TrayIconController` / `TrayIconState` — menu-bar icon, independent of the main window, keeps hotkey dictation working when unfocused.
- `AgentRouter` + `FoundationModelsAgentClassifier` — when Agent mode is on, classifies each finalized utterance on-device (Apple Foundation Models, no network) into mac-control / code-change / chat.
- `MacControlTools` — native implementations of mac-control intents (open app/URL, volume, mute, lock, sleep display, screenshot, media control), shells out to `osascript`/`open`/`pmset`/`screencapture`; speaks a confirmation via `TTSService` (`AVSpeechSynthesizer`, offline).
- `ClaudeCodeSession` / `ClaudeStreamEvent` / `PendingEdit` — code-change intents spawn `claude --output-format stream-json` scoped to a configured repo root (set in the sidebar, persisted via `UserDefaults`; use a scratch repo, not `warble` itself, while testing). The stream is parsed live; `Edit`/`Write` tool_use events are turned into diffs client-side — Claude Code's own file-write permission prompt is never approved, so Claude Code itself never touches disk. Sessions are multi-turn (resumed via `session_id`), and pending edits only reach disk via the UI-only **Apply** button (never voice-triggered); **Discard** drops them. This UI-only-write boundary is deliberate — preserve it in any changes to this flow.
- `SessionHistory` — sidebar log of every dictation/mac-control/code-change session, independent of the center panel's live stream.
- `FeedbackStore` — persists every transcription as WAV + `metadata.csv` row to `data/feedback/`, byte-for-byte compatible with the old Python server's schema, so `training/prepare_dataset.py --include-feedback` keeps working unchanged.

The UI is a Cursor-like layout: sidebar (mode toggle, code-change repo root field, session history) + center panel (live transcript/agent/code-change stream, diff review).

## Conventions

- Audio is always 16 kHz mono WAV.
- Training deps for Colab live in `requirements.txt`; local deps in `pyproject.toml` — keep them in sync.
- Issues are tracked as GitHub issues in `samuelj1323/warble` via `gh` (see `docs/agents/issue-tracker.md`); triage labels in `docs/agents/triage-labels.md`.
- Domain docs (`CONTEXT.md`, `docs/adr/`) follow the single-context convention in `docs/agents/domain.md`.
