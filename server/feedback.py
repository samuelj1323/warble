"""Feedback store: keeps transcribed audio + user corrections as training pairs.

Every transcription (live utterance or record-mode take) is saved as a 16 kHz
WAV in data/feedback/ with a row in metadata.csv. The UI can then mark it
correct or supply a corrected transcript. prepare_dataset.py --include-feedback
merges rows that have a corrected_text or a 'correct' rating.
"""

import csv
import uuid
from datetime import datetime, timezone
from pathlib import Path

import numpy as np
import soundfile as sf

FIELDS = [
    "id", "file_name", "source", "predicted_text",
    "corrected_text", "rating", "created_at",
]


class FeedbackStore:
    def __init__(self, directory: Path):
        self.dir = directory
        self.csv_path = directory / "metadata.csv"
        self.dir.mkdir(parents=True, exist_ok=True)
        if not self.csv_path.exists():
            self._write_rows([])

    def _read_rows(self) -> list[dict]:
        with self.csv_path.open(newline="", encoding="utf-8") as f:
            return list(csv.DictReader(f))

    def _write_rows(self, rows: list[dict]) -> None:
        with self.csv_path.open("w", newline="", encoding="utf-8") as f:
            writer = csv.DictWriter(f, fieldnames=FIELDS)
            writer.writeheader()
            writer.writerows(rows)

    def add(self, pcm: np.ndarray, source: str, predicted_text: str) -> dict:
        """Save a 16 kHz int16 PCM utterance and register its row. Returns the row."""
        fid = datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S") + "-" + uuid.uuid4().hex[:6]
        file_name = f"{fid}.wav"
        sf.write(self.dir / file_name, pcm.astype(np.float32) / 32768.0, 16000, subtype="PCM_16")
        row = {
            "id": fid,
            "file_name": file_name,
            "source": source,
            "predicted_text": predicted_text,
            "corrected_text": "",
            "rating": "",
            "created_at": datetime.now(timezone.utc).isoformat(),
        }
        rows = self._read_rows()
        rows.append(row)
        self._write_rows(rows)
        return row

    def update(self, fid: str, corrected_text: str | None = None, rating: str | None = None) -> dict | None:
        rows = self._read_rows()
        for row in rows:
            if row["id"] == fid:
                if corrected_text is not None:
                    row["corrected_text"] = corrected_text
                if rating is not None:
                    row["rating"] = rating
                self._write_rows(rows)
                return row
        return None
