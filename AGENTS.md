# AGENTS.md

## What this is
Warble builds a personalized speech-to-text model: fine-tuned open-weights Whisper on the owner's voice. Training runs on free cloud GPUs (Colab/Kaggle); recording, prep, and (later) serving run locally on an Apple M1 with 8 GB RAM.

## Environment
- macOS arm64, Apple M1, 8 GB unified memory — only whisper-tiny/base smoke tests locally; real training is for Colab.
- Python 3.13 venv at `.venv/` managed by **uv** (use `uv pip install --python .venv/bin/python ...`).
- `ffmpeg` (Homebrew) is required for audio decode/convert.
- Run scripts as `.venv/bin/python training/...` from the repo root.

## Commands
- Recorder app: `.venv/bin/python recorder/app.py` → http://127.0.0.1:8000
- Build dataset: `.venv/bin/python training/prepare_dataset.py`
- Local smoke test: `.venv/bin/python training/train.py --model openai/whisper-tiny --epochs 1 --batch-size 4`
- Evaluate: `.venv/bin/python training/eval.py`
- Ad-hoc transcription: `.venv/bin/python training/transcribe.py <audio-file> [--model ...]`
- Convert for serving: `.venv/bin/ct2-transformers-converter --model models/whisper-warble/final --output_dir models/whisper-warble-ct2 --quantization int8` then copy `tokenizer.json`, `tokenizer_config.json`, `preprocessor_config.json` from `final/` into the ct2 dir
- Backend: `.venv/bin/python server/app.py` → ws://127.0.0.1:8001
- Electron client: `cd electron && npm install && npm start` (menu-bar app; needs the backend running)
- Merge feedback into training data: `.venv/bin/python training/prepare_dataset.py --include-feedback`

## Conventions
- Audio is always 16 kHz mono WAV; clips are capped at 30 s (Whisper's window).
- `data/raw/metadata.csv` (file_name,text) is the source of truth for the dataset; the recorder maintains it.
- Processed datasets store relative file names only — audio is resolved via `--data-dir` at train/eval time so the tree can move to Drive/Colab unchanged.
- `data/`, `models/`, `.venv/` are gitignored; never commit audio or checkpoints.
- WER is the primary metric, computed on lowercase/punctuation-stripped text (see `training/eval.py`).
- Training deps for Colab live in `requirements.txt`; local deps in `pyproject.toml` — keep them in sync.

## Architecture notes
- `server/app.py` serves the CTranslate2 int8 build of the fine-tuned model (`models/whisper-warble-ct2`) via faster-whisper on CPU. It's a pure backend now — no static UI — the Electron app (`electron/`) is the only client. The ct2 converter does NOT copy tokenizer files — they must be copied from `final/` (see command above).
- The recorder (port 8000) and the main app (port 8001) are separate FastAPI apps.
- `electron/` is the menu-bar dictation client: tray icon, global hotkey (⌘⇧D), mic capture via `MediaRecorder` in the renderer, paste-into-focused-app via `@nut-tree-fork/nut-js` in the main process.
- Live mode: the client streams webm/opus chunks over `/ws`; `server/streaming.py` pipes them through ffmpeg to 16kHz PCM and uses Silero VAD (`faster_whisper.vad`) to cut utterances on ~0.7s trailing silence (or a 15s max). Each utterance is transcribed and pushed back as a `{"type": "final", ...}` message.
- Agent mode: `/ws?agent=true` additionally routes each final transcript through `server/agent.py`, which calls OpenRouter (`OPENROUTER_API_KEY` in `.env`) with tool schemas from `server/tools.py` (currently `open_app`, `open_url` — deliberately no raw shell execution, since arguments come from an untrusted voice transcript). Results come back as a `{"type": "agent", "reply": ..., "actions": [...]}` message; the Electron client skips pasting and shows these in its history list instead.
- Every transcription (record or live) is persisted by `server/feedback.py` to `data/feedback/` (WAV + row in `metadata.csv`) regardless of user action. `training/prepare_dataset.py --include-feedback` merges rows with a `corrected_text` or `rating == "correct"` into the next dataset build, copying their WAVs into `--data-dir` so file paths stay relative like recorder clips.

## Agent skills

### Issue tracker

Issues live as GitHub issues in `samuelj1323/warble` (via `gh`). See `docs/agents/issue-tracker.md`.

### Triage labels

Default five canonical roles, unchanged. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: `CONTEXT.md` + `docs/adr/` at the repo root. See `docs/agents/domain.md`.

## Roadmap
- Phase 5 is built: Electron menu-bar client with live dictation, paste-on-finalize, and a feedback loop (correct/fix transcriptions → merged into future fine-tunes via `--include-feedback`). Agent mode (voice → tool calls via OpenRouter) is built on top of it.
- Possible next steps: surface feedback-driven WER improvements after a re-train; hands-free wake-word activation for live mode; more agent tools; packaging/signing the Electron app.
