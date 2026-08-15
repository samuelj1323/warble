"""Transcribe an audio file with your fine-tuned model (or stock Whisper).

Usage:
  .venv/bin/python training/transcribe.py path/to/audio.wav
  .venv/bin/python training/transcribe.py memo.m4a --model openai/whisper-small

Any format ffmpeg understands works (wav, mp3, m4a, webm, ...).
"""

import argparse
import sys
from pathlib import Path

import torch
from transformers import pipeline

DEFAULT_MODEL = Path("models/whisper-warble/final")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("audio", type=Path, help="Audio file to transcribe")
    parser.add_argument("--model", default=str(DEFAULT_MODEL),
                        help="Local model dir or Hugging Face model id")
    args = parser.parse_args()

    if not args.audio.exists():
        sys.exit(f"No such file: {args.audio}")
    if args.model == str(DEFAULT_MODEL) and not DEFAULT_MODEL.exists():
        sys.exit(
            f"{DEFAULT_MODEL} not found — train the model first (training/finetune.ipynb),\n"
            f"or pass a stock model: --model openai/whisper-small"
        )

    device = "mps" if torch.backends.mps.is_available() else ("cuda:0" if torch.cuda.is_available() else "cpu")
    pipe = pipeline(
        "automatic-speech-recognition",
        model=args.model,
        device=device,
        chunk_length_s=30,  # enables long-form transcription for files over 30s
        generate_kwargs={"language": "en", "task": "transcribe"},
    )
    result = pipe(str(args.audio))
    print(result["text"])


if __name__ == "__main__":
    main()
