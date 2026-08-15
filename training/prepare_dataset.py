"""Validate recorded clips and build the train/val/test splits.

Usage: python training/prepare_dataset.py [--data-dir data/raw] [--out-dir data/processed]

Reads metadata.csv (file_name,text) produced by the recorder, drops bad clips,
and saves a Hugging Face DatasetDict. Audio stays on disk as WAVs; the dataset
stores relative file names so it can be moved to Colab/Drive as-is.
"""

import argparse
import csv
import random
import shutil
from pathlib import Path

import soundfile as sf
from datasets import Dataset, DatasetDict

SAMPLE_RATE = 16000
MIN_DURATION_S = 0.5
MAX_DURATION_S = 30.0
SEED = 42


def collect_feedback(feedback_dir: Path, data_dir: Path) -> list[dict]:
    """Copy qualifying feedback clips into data_dir and return their metadata rows.

    A feedback row qualifies once the user has confirmed it: either a
    corrected_text was supplied, or it was rated "correct". Clips are copied
    (not referenced in place) so file_name stays relative to data_dir, same as
    recorder clips — keeps the "move data/ to Drive unchanged" invariant.
    """
    metadata = feedback_dir / "metadata.csv"
    if not metadata.exists():
        return []

    rows = []
    with metadata.open(newline="", encoding="utf-8") as f:
        for row in csv.DictReader(f):
            corrected = row["corrected_text"].strip()
            text = corrected or (row["predicted_text"].strip() if row["rating"] == "correct" else "")
            if not text:
                continue
            src = feedback_dir / row["file_name"]
            if not src.exists():
                continue
            file_name = f"feedback-{row['id']}.wav"
            dst = data_dir / file_name
            if not dst.exists():
                shutil.copy2(src, dst)
            rows.append({"file_name": file_name, "text": text})
    return rows


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--data-dir", type=Path, default=Path("data/raw"))
    parser.add_argument("--out-dir", type=Path, default=Path("data/processed"))
    parser.add_argument("--val-frac", type=float, default=0.10)
    parser.add_argument("--test-frac", type=float, default=0.05)
    parser.add_argument(
        "--include-feedback",
        action="store_true",
        help="merge confirmed corrections/ratings from data/feedback into the dataset",
    )
    parser.add_argument("--feedback-dir", type=Path, default=Path("data/feedback"))
    args = parser.parse_args()

    metadata = args.data_dir / "metadata.csv"
    if not metadata.exists():
        raise SystemExit(f"No metadata.csv in {args.data_dir} — record some clips first.")

    with metadata.open(newline="", encoding="utf-8") as f:
        candidates = [
            {"file_name": row["file_name"].strip(), "text": row["text"].strip()}
            for row in csv.DictReader(f)
        ]

    if args.include_feedback:
        feedback_rows = collect_feedback(args.feedback_dir, args.data_dir)
        candidates.extend(feedback_rows)
        print(f"Merged {len(feedback_rows)} confirmed feedback clips from {args.feedback_dir}")

    records, skipped = [], []
    for row in candidates:
        file_name, text = row["file_name"], row["text"]
        path = args.data_dir / file_name
        if not path.exists():
            skipped.append((file_name, "file missing"))
            continue
        info = sf.info(path)
        duration = info.frames / info.samplerate
        if info.samplerate != SAMPLE_RATE:
            skipped.append((file_name, f"sample rate {info.samplerate}"))
        elif duration < MIN_DURATION_S or duration > MAX_DURATION_S:
            skipped.append((file_name, f"duration {duration:.1f}s"))
        elif not text:
            skipped.append((file_name, "empty transcript"))
        else:
            records.append({"file_name": file_name, "text": text, "duration": duration})

    if len(records) < 10:
        raise SystemExit(
            f"Only {len(records)} valid clips — record more before preparing a dataset."
        )

    random.Random(SEED).shuffle(records)
    n = len(records)
    n_test = max(1, round(n * args.test_frac))
    n_val = max(1, round(n * args.val_frac))
    test = records[:n_test]
    val = records[n_test : n_test + n_val]
    train = records[n_test + n_val :]

    ds = DatasetDict(
        {
            "train": Dataset.from_list(train),
            "validation": Dataset.from_list(val),
            "test": Dataset.from_list(test),
        }
    )
    args.out_dir.mkdir(parents=True, exist_ok=True)
    ds.save_to_disk(str(args.out_dir))

    hours = sum(r["duration"] for r in records) / 3600
    print(f"Valid clips: {n} ({hours:.2f} hours)")
    print(f"Splits: train={len(train)}, validation={len(val)}, test={len(test)}")
    if skipped:
        print(f"Skipped {len(skipped)} clips:")
        for name, reason in skipped:
            print(f"  {name}: {reason}")
    print(f"Saved to {args.out_dir}")


if __name__ == "__main__":
    main()
