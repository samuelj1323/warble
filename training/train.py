"""Fine-tune Whisper on your recorded voice.

The same script runs locally (M-series Mac, smoke tests with whisper-tiny) and
on Colab/Kaggle GPUs (real runs with whisper-small). Examples:

  # local smoke test
  python training/train.py --model openai/whisper-tiny --epochs 1 --batch-size 4

  # Colab GPU run
  python training/train.py --model openai/whisper-small --epochs 3 \
      --batch-size 8 --grad-accum 4 --fp16 --num-workers 2
"""

import argparse
from dataclasses import dataclass
from pathlib import Path

import numpy as np
import soundfile as sf
import torch
from datasets import load_from_disk
from jiwer import Compose, RemovePunctuation, Strip, ToLowerCase
from jiwer import wer as jiwer_wer
from transformers import (
    EarlyStoppingCallback,
    Seq2SeqTrainer,
    Seq2SeqTrainingArguments,
    WhisperForConditionalGeneration,
    WhisperProcessor,
)

SAMPLE_RATE = 16000


@dataclass
class DataCollatorSpeechSeq2SeqWithPadding:
    """Pads label sequences; Whisper features are already fixed-size (80 x 3000)."""

    processor: WhisperProcessor

    def __call__(self, features: list[dict]) -> dict[str, torch.Tensor]:
        input_features = torch.tensor(
            np.array([f["input_features"] for f in features]), dtype=torch.float32
        )
        label_features = [{"input_ids": f["labels"]} for f in features]
        labels_batch = self.processor.tokenizer.pad(label_features, return_tensors="pt")
        labels = labels_batch["input_ids"].masked_fill(
            labels_batch.attention_mask.ne(1), -100
        )
        # If a BOS token was appended during tokenization, cut it — the model
        # shifts labels internally and adds the decoder start token itself.
        if (labels[:, 0] == self.processor.tokenizer.bos_token_id).all().cpu().item():
            labels = labels[:, 1:]
        return {"input_features": input_features, "labels": labels}


NORMALIZE = Compose([ToLowerCase(), RemovePunctuation(), Strip()])


def normalized_wer(references: list[str], hypotheses: list[str]) -> float:
    refs = [NORMALIZE(r) for r in references]
    hyps = [NORMALIZE(h) for h in hypotheses]
    # jiwer refuses empty reference lists after normalization; guard per-sample
    pairs = [(r, h) for r, h in zip(refs, hyps) if r]
    return jiwer_wer([r for r, _ in pairs], [h for _, h in pairs]) if pairs else 0.0


def pick_device() -> torch.device:
    if torch.cuda.is_available():
        return torch.device("cuda")
    if torch.backends.mps.is_available():
        return torch.device("mps")
    return torch.device("cpu")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--data-dir", type=Path, default=Path("data/raw"))
    parser.add_argument("--dataset-dir", type=Path, default=Path("data/processed"))
    parser.add_argument("--output-dir", type=Path, default=Path("models/whisper-warble"))
    parser.add_argument("--model", default="openai/whisper-small")
    parser.add_argument("--epochs", type=float, default=3.0)
    parser.add_argument("--max-steps", type=int, default=-1)
    parser.add_argument("--batch-size", type=int, default=8)
    parser.add_argument("--grad-accum", type=int, default=4)
    parser.add_argument("--lr", type=float, default=1e-5)
    parser.add_argument("--warmup-steps", type=int, default=50)
    parser.add_argument("--eval-steps", type=int, default=100)
    parser.add_argument("--freeze-encoder", action="store_true",
                        help="Only train the decoder — helps with very small datasets")
    parser.add_argument("--fp16", action="store_true", help="Only use on CUDA GPUs")
    parser.add_argument("--num-workers", type=int, default=0)
    parser.add_argument("--early-stopping-patience", type=int, default=3)
    parser.add_argument("--seed", type=int, default=42)
    args = parser.parse_args()

    device = pick_device()
    fp16 = args.fp16 and device.type == "cuda"
    if args.fp16 and not fp16:
        print("fp16 requested but no CUDA GPU — running in fp32.")
    print(f"Device: {device} | model: {args.model}")

    processor = WhisperProcessor.from_pretrained(args.model, language="en", task="transcribe")
    ds = load_from_disk(str(args.dataset_dir))
    print(f"Dataset: {ds}")

    def prepare(batch):
        audio, sr = sf.read(args.data_dir / batch["file_name"], dtype="float32")
        if sr != SAMPLE_RATE:
            raise ValueError(f"{batch['file_name']}: expected {SAMPLE_RATE} Hz, got {sr}")
        batch["input_features"] = processor.feature_extractor(
            audio, sampling_rate=SAMPLE_RATE
        ).input_features[0]
        batch["labels"] = processor.tokenizer(batch["text"]).input_ids
        return batch

    vectorized = ds.map(
        prepare,
        remove_columns=ds["train"].column_names,
        num_proc=args.num_workers if args.num_workers > 0 else None,
        desc="Extracting log-mel features",
    )

    model = WhisperForConditionalGeneration.from_pretrained(args.model)
    model.generation_config.language = "en"
    model.generation_config.task = "transcribe"
    model.generation_config.forced_decoder_ids = None
    model.config.use_cache = False  # required with gradient checkpointing
    if args.freeze_encoder:
        for param in model.model.encoder.parameters():
            param.requires_grad = False
        trainable = sum(p.numel() for p in model.parameters() if p.requires_grad)
        print(f"Encoder frozen — {trainable / 1e6:.1f}M trainable parameters")

    def compute_metrics(pred):
        pred_ids = pred.predictions
        label_ids = pred.label_ids
        label_ids[label_ids == -100] = processor.tokenizer.pad_token_id
        pred_str = processor.tokenizer.batch_decode(pred_ids, skip_special_tokens=True)
        label_str = processor.tokenizer.batch_decode(label_ids, skip_special_tokens=True)
        return {"wer": normalized_wer(label_str, pred_str)}

    training_args = Seq2SeqTrainingArguments(
        output_dir=str(args.output_dir),
        per_device_train_batch_size=args.batch_size,
        per_device_eval_batch_size=args.batch_size,
        gradient_accumulation_steps=args.grad_accum,
        learning_rate=args.lr,
        warmup_steps=args.warmup_steps,
        num_train_epochs=args.epochs,
        max_steps=args.max_steps,
        gradient_checkpointing=True,
        fp16=fp16,
        eval_strategy="steps",
        eval_steps=args.eval_steps,
        save_steps=args.eval_steps,
        logging_steps=25,
        predict_with_generate=True,
        generation_max_length=225,
        load_best_model_at_end=True,
        metric_for_best_model="wer",
        greater_is_better=False,
        dataloader_num_workers=args.num_workers,
        dataloader_pin_memory=device.type == "cuda",
        report_to=[],
        seed=args.seed,
        save_total_limit=3,
    )

    callbacks = []
    if args.early_stopping_patience > 0:
        callbacks.append(EarlyStoppingCallback(early_stopping_patience=args.early_stopping_patience))

    trainer = Seq2SeqTrainer(
        model=model,
        args=training_args,
        train_dataset=vectorized["train"],
        eval_dataset=vectorized["validation"],
        data_collator=DataCollatorSpeechSeq2SeqWithPadding(processor),
        compute_metrics=compute_metrics,
        processing_class=processor.feature_extractor,
        callbacks=callbacks,
    )

    trainer.train()

    final_dir = args.output_dir / "final"
    trainer.save_model(str(final_dir))  # best checkpoint, thanks to load_best_model_at_end
    processor.save_pretrained(str(final_dir))
    print(f"Saved best model to {final_dir}")


if __name__ == "__main__":
    main()
