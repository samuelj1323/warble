"""Compare stock Whisper vs your fine-tuned model on the held-out test split.

Usage: python training/eval.py [--model-dir models/whisper-warble/final]

Prints normalized WER/CER for each model plus example diffs, and writes a JSON
report to models/eval_results.json.
"""

import argparse
import json
from pathlib import Path

import soundfile as sf
import torch
from datasets import load_from_disk
from jiwer import Compose, RemovePunctuation, Strip, ToLowerCase, cer, wer
from transformers import pipeline

SAMPLE_RATE = 16000
NORMALIZE = Compose([ToLowerCase(), RemovePunctuation(), Strip()])


def transcribe_all(pipe, dataset, data_dir: Path) -> list[str]:
    hypotheses = []
    for i, row in enumerate(dataset):
        audio, sr = sf.read(data_dir / row["file_name"], dtype="float32")
        if sr != SAMPLE_RATE:
            raise ValueError(f"{row['file_name']}: expected {SAMPLE_RATE} Hz, got {sr}")
        result = pipe({"array": audio, "sampling_rate": SAMPLE_RATE})
        hypotheses.append(result["text"])
        if (i + 1) % 10 == 0:
            print(f"  {i + 1}/{len(dataset)} transcribed")
    return hypotheses


def score(references: list[str], hypotheses: list[str]) -> dict:
    refs = [NORMALIZE(r) for r in references]
    hyps = [NORMALIZE(h) for h in hypotheses]
    pairs = [(r, h) for r, h in zip(refs, hyps) if r]
    r, h = [p[0] for p in pairs], [p[1] for p in pairs]
    return {"wer": wer(r, h), "cer": cer(r, h)}


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--model-dir", type=Path, default=Path("models/whisper-warble/final"))
    parser.add_argument("--base-model", default="openai/whisper-small")
    parser.add_argument("--dataset-dir", type=Path, default=Path("data/processed"))
    parser.add_argument("--data-dir", type=Path, default=Path("data/raw"))
    parser.add_argument("--split", default="test")
    parser.add_argument("--report", type=Path, default=Path("models/eval_results.json"))
    args = parser.parse_args()

    device = "cuda:0" if torch.cuda.is_available() else ("mps" if torch.backends.mps.is_available() else "cpu")
    print(f"Device: {device}")

    test = load_from_disk(str(args.dataset_dir))[args.split]
    references = [row["text"] for row in test]
    print(f"Evaluating on {len(test)} clips from split '{args.split}'")

    report = {}
    outputs = {}
    for name, model_ref in [("stock", args.base_model), ("finetuned", str(args.model_dir))]:
        print(f"\n== {name}: {model_ref} ==")
        pipe = pipeline(
            "automatic-speech-recognition",
            model=model_ref,
            device=device,
            generate_kwargs={"language": "en", "task": "transcribe"},
        )
        hyps = transcribe_all(pipe, test, args.data_dir)
        report[name] = score(references, hyps)
        outputs[name] = hyps
        del pipe
        if device.startswith("cuda"):
            torch.cuda.empty_cache()

    print("\n== Results (normalized) ==")
    for name, m in report.items():
        print(f"{name:>10}: WER {m['wer']:.3f} | CER {m['cer']:.3f}")
    delta = report["stock"]["wer"] - report["finetuned"]["wer"]
    print(f"\nWER improvement from fine-tuning: {delta:+.3f}")

    print("\n== Sample diffs (fine-tuned still wrong) ==")
    shown = 0
    for ref, stock_h, ft_h in zip(references, outputs["stock"], outputs["finetuned"]):
        if NORMALIZE(ref) != NORMALIZE(ft_h) and shown < 5:
            print(f"\n  REF:        {ref}")
            print(f"  STOCK:      {stock_h}")
            print(f"  FINETUNED:  {ft_h}")
            shown += 1
    if shown == 0:
        print("  None — fine-tuned model matched every reference.")

    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(json.dumps(report, indent=2))
    print(f"\nReport written to {args.report}")


if __name__ == "__main__":
    main()
