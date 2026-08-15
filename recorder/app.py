"""Warble recorder: serves reading prompts and stores 16kHz mono WAV clips.

Run:  uv run recorder/app.py   (or: .venv/bin/python recorder/app.py)
Then open http://127.0.0.1:8000
"""

import csv
import subprocess
import tempfile
from contextlib import asynccontextmanager
from pathlib import Path

import numpy as np
import soundfile as sf
from fastapi import FastAPI, File, Form, HTTPException, UploadFile
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles

BASE_DIR = Path(__file__).resolve().parent.parent
DATA_DIR = BASE_DIR / "data" / "raw"
PROMPTS_FILE = BASE_DIR / "recorder" / "prompts.txt"
METADATA_FILE = DATA_DIR / "metadata.csv"
SAMPLE_RATE = 16000

MIN_DURATION_S = 0.5
MAX_DURATION_S = 30.0
SILENCE_RMS = 0.001  # below this the clip is probably a dead mic
CLIP_PEAK = 0.99     # at/above this the clip is probably clipping

@asynccontextmanager
async def lifespan(app: FastAPI):
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    yield


app = FastAPI(title="Warble Recorder", lifespan=lifespan)


def load_prompts() -> list[str]:
    lines = PROMPTS_FILE.read_text(encoding="utf-8").splitlines()
    return [l.strip() for l in lines if l.strip() and not l.startswith("#")]


PROMPTS = load_prompts()


def wav_path(index: int) -> Path:
    return DATA_DIR / f"{index:04d}.wav"


def recorded_indices() -> set[int]:
    return {int(p.stem) for p in DATA_DIR.glob("*.wav") if p.stem.isdigit()}


def write_metadata(rows: dict[int, str]) -> None:
    with METADATA_FILE.open("w", newline="", encoding="utf-8") as f:
        writer = csv.writer(f)
        writer.writerow(["file_name", "text"])
        for idx in sorted(rows):
            writer.writerow([f"{idx:04d}.wav", rows[idx]])


def read_metadata() -> dict[int, str]:
    if not METADATA_FILE.exists():
        return {}
    with METADATA_FILE.open(newline="", encoding="utf-8") as f:
        return {
            int(row["file_name"][:4]): row["text"]
            for row in csv.DictReader(f)
        }


@app.get("/")
def index() -> FileResponse:
    return FileResponse(BASE_DIR / "recorder" / "static" / "index.html")


@app.get("/api/prompts/next")
def next_prompt() -> dict:
    done = recorded_indices()
    for i, text in enumerate(PROMPTS):
        if i not in done:
            return {
                "index": i,
                "text": text,
                "done_count": len(done),
                "total": len(PROMPTS),
                "finished": False,
            }
    return {"done_count": len(done), "total": len(PROMPTS), "finished": True}


@app.get("/api/prompts/{index}")
def get_prompt(index: int) -> dict:
    if not 0 <= index < len(PROMPTS):
        raise HTTPException(status_code=404, detail="prompt index out of range")
    return {
        "index": index,
        "text": PROMPTS[index],
        "recorded": wav_path(index).exists(),
    }


@app.post("/api/record")
async def record(index: int = Form(...), file: UploadFile = File(...)) -> dict:
    if not 0 <= index < len(PROMPTS):
        raise HTTPException(status_code=400, detail="prompt index out of range")

    suffix = Path(file.filename or "audio.webm").suffix or ".webm"
    with tempfile.NamedTemporaryFile(suffix=suffix, delete=False) as tmp:
        tmp.write(await file.read())
        tmp_path = Path(tmp.name)

    out_path = wav_path(index)
    try:
        subprocess.run(
            [
                "ffmpeg", "-y", "-v", "error",
                "-i", str(tmp_path),
                "-ac", "1", "-ar", str(SAMPLE_RATE),
                "-f", "wav", str(out_path),
            ],
            check=True,
            capture_output=True,
        )
    except subprocess.CalledProcessError as e:
        raise HTTPException(
            status_code=400,
            detail=f"ffmpeg could not decode upload: {e.stderr.decode(errors='replace')}",
        )
    finally:
        tmp_path.unlink(missing_ok=True)

    # Quality gate: warn, don't reject — the user decides whether to re-record.
    warnings: list[str] = []
    audio, sr = sf.read(out_path)
    duration = len(audio) / sr
    if sr != SAMPLE_RATE:
        warnings.append(f"unexpected sample rate {sr}")
    if duration < MIN_DURATION_S:
        warnings.append(f"clip is very short ({duration:.1f}s)")
    if duration > MAX_DURATION_S:
        warnings.append(f"clip is very long ({duration:.1f}s)")
    rms = float(np.sqrt(np.mean(np.square(audio)))) if len(audio) else 0.0
    if rms < SILENCE_RMS:
        warnings.append("clip looks silent — check your mic")
    if len(audio) and float(np.max(np.abs(audio))) >= CLIP_PEAK:
        warnings.append("clip may be clipping — move further from the mic")

    rows = read_metadata()
    rows[index] = PROMPTS[index]
    write_metadata(rows)

    return {
        "ok": True,
        "index": index,
        "file": out_path.name,
        "duration_s": round(duration, 2),
        "warnings": warnings,
        "done_count": len(recorded_indices()),
        "total": len(PROMPTS),
    }


app.mount("/static", StaticFiles(directory=BASE_DIR / "recorder" / "static"), name="static")

if __name__ == "__main__":
    import uvicorn

    uvicorn.run(app, host="127.0.0.1", port=8000)
