# Warble

Personalized speech-to-text: fine-tune [openai/whisper-small](https://huggingface.co/openai/whisper-small) on recordings of your own voice, then run it fully offline. No transcription APIs — the model is yours.

## How it works

1. **Record** — a local web app shows you sentences to read aloud and saves 16 kHz WAV clips with transcripts.
2. **Prepare** — a script validates the clips and builds train/val/test splits.
3. **Train** — a Colab notebook (free T4 GPU) fine-tunes Whisper on your clips; the finished model downloads back to your Mac as a zip.
4. **Evaluate** — WER report comparing stock Whisper vs your fine-tune on held-out clips.
5. **Serve** — a local FastAPI backend + browser UI, running an int8 CTranslate2 build of your model on CPU.

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

One-time: convert the fine-tuned model to CTranslate2 int8 (fast CPU inference):

```bash
.venv/bin/ct2-transformers-converter --model models/whisper-warble/final \
    --output_dir models/whisper-warble-ct2 --quantization int8
cp models/whisper-warble/final/{tokenizer.json,tokenizer_config.json,preprocessor_config.json} \
    models/whisper-warble-ct2/
```

Build the React frontend (one time, or after UI changes):

```bash
cd app && npm install && npm run build && cd ..
```

Then:

```bash
.venv/bin/python server/app.py
# open http://127.0.0.1:8001
```

Two modes:
- **Record** — hit Record, speak, Stop, then Transcribe (record-then-send).
- **Live** — hit Start listening; the server VAD-segments your speech and streams back a transcript per utterance as you talk.

Every transcription — either mode — is saved as feedback (WAV + prediction). Mark it **Correct** or edit the text and **Save fix** to build a corrections dataset for your next fine-tune. Feedback lives in `data/feedback/`; merge it into the next training run with:

```bash
.venv/bin/python training/prepare_dataset.py --include-feedback
```

For frontend development with hot reload, run the Vite dev server (proxies `/transcribe`, `/feedback`, `/ws` to the FastAPI backend on :8001) alongside the backend:

```bash
.venv/bin/python server/app.py           # terminal 1 — backend on :8001
cd app && npm run dev                    # terminal 2 — UI on :5173 with HMR
```

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
  app.py             FastAPI: /transcribe, /ws (live), /feedback (port 8001)
  streaming.py        VAD-based utterance segmentation for live mode
  feedback.py         saves transcriptions + corrections as training pairs
app/                  React + Vite frontend (Record / Live modes, feedback UI); builds to app/dist
web/index.html       legacy vanilla-JS UI (superseded by app/)
data/raw/            your WAVs + metadata.csv (gitignored)
data/feedback/       transcriptions + corrections from using the app (gitignored)
data/processed/      HF dataset splits (gitignored)
models/              fine-tuned checkpoints + ct2 build (gitignored)
```
