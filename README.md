# Warble

Personalized speech-to-text: fine-tune [openai/whisper-small](https://huggingface.co/openai/whisper-small) on recordings of your own voice, then run it fully offline. No transcription APIs — the model is yours.

## How it works

1. **Record** — a local web app shows you sentences to read aloud and saves 16 kHz WAV clips with transcripts.
2. **Prepare** — a script validates the clips and builds train/val/test splits.
3. **Train** — a Colab notebook (free T4 GPU) fine-tunes Whisper on your clips; the finished model downloads back to your Mac as a zip.
4. **Evaluate** — WER report comparing stock Whisper vs your fine-tune on held-out clips.
5. **Serve** — a native macOS app (WarbleMac) runs your fine-tuned model on-device via WhisperKit/CoreML.

## Setup (Mac)

```bash
brew install ffmpeg uv
uv sync   # creates .venv and installs everything from pyproject.toml
```

## Recording your voice

```bash
.venv/bin/python recorder/app.py
# open http://127.0.0.1:8000
```

Read each prompt aloud, listen to the take, save it. Progress is saved after every clip — record in 15–20 minute sessions. Target: 1–2 hours of audio (~500 prompts).

- Edit `recorder/prompts.txt` (Section E) to include your name, coworkers, places, and jargon — this is where personalization pays off.
- Use the same mic you plan to use with the final app.
- Already-recorded prompts are skipped automatically; re-record any take by saving again.

## Preparing the dataset

```bash
.venv/bin/python training/prepare_dataset.py
# Valid clips: 480 (1.05 hours)
# Splits: train=408, validation=48, test=24
```

## Training (free GPU)

Open `training/finetune.ipynb` in Google Colab and follow the cells. You'll upload the `warble` folder to Google Drive (via the website) so Colab can reach your recordings; when training finishes, the notebook's last cell downloads the model to your browser as `whisper-warble-final.zip` — then:

```bash
unzip ~/Downloads/whisper-warble-final.zip -d models/whisper-warble/
```

(No Google Drive desktop app or sync setup required.) The same training script runs locally for smoke tests:

```bash
# quick pipeline check on this Mac (tiny model, ~minutes)
.venv/bin/python training/train.py --model openai/whisper-tiny --epochs 1 --batch-size 4
```

Useful flags: `--freeze-encoder` (small datasets), `--lr`, `--epochs`, `--batch-size`, `--grad-accum`, `--early-stopping-patience`.

## Evaluating

```bash
.venv/bin/python training/eval.py
#      stock: WER 0.118 | CER 0.051
#  finetuned: WER 0.062 | CER 0.024
```

## Trying it out

```bash
# transcribe any audio file with your fine-tuned model
.venv/bin/python training/transcribe.py path/to/voice-memo.m4a

# compare against stock whisper on the same file
.venv/bin/python training/transcribe.py path/to/voice-memo.m4a --model openai/whisper-small
```

## Running the app

Warble runs as a native macOS app, **WarbleMac** — a Swift Package (SwiftUI), replacing the old Electron client + Python backend entirely. See [`WarbleMac/README.md`](WarbleMac/README.md) for the one-time model-conversion step (fine-tuned checkpoint → CoreML via WhisperKit), required permissions (microphone, Accessibility for paste, automation for Mac-control tools), and how to configure the fixed repo root used by the code-change agent.

```bash
cd WarbleMac
swift run
```

This opens a Cursor-like window: a sidebar (dictation/agent mode toggle, session history) alongside a center panel (live transcript, Mac-control agent replies, and a Claude-Code-backed code-change diff view with Apply/Discard). The global hotkey (⌘⇧D) and tray icon still work for hotkey-triggered dictation when the window isn't focused. Every transcription is still saved as feedback (WAV + prediction) to `data/feedback/`, in the same format the old Python server used, so it merges into training unchanged:

```bash
.venv/bin/python training/prepare_dataset.py --include-feedback
```

**Agent mode** — flip the toggle in the sidebar: instead of pasting the transcript into whatever app has focus, it's classified on-device (Apple's Foundation Models framework, no network call, replacing the old OpenRouter-backed agent) as a Mac-control command, a code-change request, or chat. Mac-control commands dispatch to native tool implementations (open app/URL, volume, mute, lock screen, sleep display, screenshot, media control) and speak a confirmation. Code-change requests are handed to a `claude` CLI subprocess scoped to a configured repo root; proposed edits render as a diff, and only an explicit **Apply** click ever writes to disk.

## Layout

```
recorder/            prompt-recording web app (FastAPI + vanilla JS)
  prompts.txt        sentences to read aloud — personalize Section E
training/
  prepare_dataset.py validate clips → train/val/test splits (--include-feedback merges corrections)
  train.py           fine-tuning script (local + Colab)
  eval.py            stock vs fine-tuned WER report
  transcribe.py      transcribe any audio file from the CLI
  finetune.ipynb     Colab notebook
server/
  feedback.py         reference for WarbleMac's native FeedbackStore (schema/format only — not run)
WarbleMac/            native macOS app (SwiftUI) — dictation, Mac-control agent, code-change agent
data/raw/            your WAVs + metadata.csv (gitignored)
data/feedback/       transcriptions + corrections from using the app (gitignored)
data/processed/      HF dataset splits (gitignored)
models/              fine-tuned checkpoints + ct2 build (gitignored)
```
