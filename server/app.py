"""Warble server: serve your fine-tuned Whisper to the browser.

Run:  .venv/bin/python server/app.py
Then open http://127.0.0.1:8001 (serves app/dist — build the React UI first
with `cd app && npm install && npm run build`, or use the vite dev server).

Endpoints:
  POST /transcribe   record-then-send (multipart audio upload)
  WS   /ws?fmt=webm  live mode: stream MediaRecorder chunks, get utterance finals
  POST /feedback     save a correction / rating for a transcription
"""

import asyncio
import subprocess
import tempfile
import time
from contextlib import asynccontextmanager
from pathlib import Path

import numpy as np
import soundfile as sf
from dotenv import load_dotenv
from fastapi import FastAPI, File, Form, HTTPException, UploadFile, WebSocket, WebSocketDisconnect
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel

from agent import run_agent
from feedback import FeedbackStore
from streaming import LiveSession

load_dotenv()

BASE_DIR = Path(__file__).resolve().parent.parent
MODEL_DIR = BASE_DIR / "models" / "whisper-warble-ct2"
DIST_DIR = BASE_DIR / "app" / "dist"
FEEDBACK_DIR = BASE_DIR / "data" / "feedback"

model = None      # faster-whisper model, loaded at startup
feedback = None   # FeedbackStore


@asynccontextmanager
async def lifespan(app: FastAPI):
    global model, feedback
    if not MODEL_DIR.exists():
        raise RuntimeError(
            f"{MODEL_DIR} not found — convert the fine-tuned model first:\n"
            "  ct2-transformers-converter --model models/whisper-warble/final "
            "--output_dir models/whisper-warble-ct2 --quantization int8"
        )
    from faster_whisper import WhisperModel

    model = WhisperModel(str(MODEL_DIR), device="cpu", compute_type="int8")
    feedback = FeedbackStore(FEEDBACK_DIR)
    yield
    model = None


app = FastAPI(title="Warble", lifespan=lifespan)


def transcribe_pcm(pcm: np.ndarray) -> tuple[str, float]:
    """16 kHz int16 PCM -> (text, elapsed_s). Blocking — call via to_thread."""
    audio = pcm.astype(np.float32) / 32768.0
    start = time.perf_counter()
    segments, _ = model.transcribe(audio, language="en", beam_size=5, vad_filter=False)
    text = " ".join(s.text.strip() for s in segments).strip()
    return text, time.perf_counter() - start


def decode_to_pcm(path: Path) -> np.ndarray:
    """Decode any audio container to 16 kHz mono int16 PCM via ffmpeg."""
    with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as tmp:
        wav = Path(tmp.name)
    try:
        subprocess.run(
            ["ffmpeg", "-y", "-v", "error", "-i", str(path),
             "-ac", "1", "-ar", "16000", "-f", "wav", str(wav)],
            check=True, capture_output=True,
        )
        pcm, _ = sf.read(wav, dtype="int16")
        return pcm
    finally:
        wav.unlink(missing_ok=True)


@app.post("/transcribe")
async def transcribe(file: UploadFile = File(...), agent: bool = Form(False)) -> dict:
    suffix = Path(file.filename or "audio.webm").suffix or ".webm"
    with tempfile.NamedTemporaryFile(suffix=suffix, delete=False) as tmp:
        tmp.write(await file.read())
        tmp_path = Path(tmp.name)

    try:
        pcm = await asyncio.to_thread(decode_to_pcm, tmp_path)
        text, elapsed = await asyncio.to_thread(transcribe_pcm, pcm)
        row = feedback.add(pcm, source="record", predicted_text=text)
    except subprocess.CalledProcessError as e:
        raise HTTPException(
            status_code=400,
            detail=f"could not decode upload: {e.stderr.decode(errors='replace')}",
        )
    finally:
        tmp_path.unlink(missing_ok=True)

    result = {
        "id": row["id"],
        "text": text,
        "audio_duration_s": round(len(pcm) / 16000, 2),
        "elapsed_s": round(elapsed, 2),
    }

    if agent and text:
        result["agent"] = await run_agent(text)

    return result


@app.websocket("/ws")
async def ws(websocket: WebSocket, fmt: str = "webm", agent: bool = False) -> None:
    await websocket.accept()

    async def on_utterance(pcm: np.ndarray) -> None:
        text, elapsed = await asyncio.to_thread(transcribe_pcm, pcm)
        row = feedback.add(pcm, source="live", predicted_text=text)
        try:
            await websocket.send_json(
                {"type": "final", "id": row["id"], "text": text, "elapsed_s": round(elapsed, 2)}
            )
        except Exception:
            return  # client already gone; the feedback pair is still saved

        if agent and text:
            agent_result = await run_agent(text)
            try:
                await websocket.send_json({"type": "agent", "id": row["id"], **agent_result})
            except Exception:
                pass

    session = LiveSession(on_utterance, container=fmt)
    await session.start()
    try:
        while True:
            message = await websocket.receive()
            if message["type"] == "websocket.disconnect":
                break
            if message.get("bytes") is not None:
                await session.feed(message["bytes"])
            elif message.get("text") is not None:
                break  # any text frame = client asking to stop
    except WebSocketDisconnect:
        pass
    finally:
        await session.finish()
        try:
            await websocket.close()
        except RuntimeError:
            pass  # already disconnected


class FeedbackIn(BaseModel):
    id: str
    corrected_text: str | None = None
    rating: str | None = None  # e.g. "correct"


@app.post("/feedback")
def submit_feedback(payload: FeedbackIn) -> dict:
    row = feedback.update(payload.id, payload.corrected_text, payload.rating)
    if row is None:
        raise HTTPException(status_code=404, detail="unknown transcription id")
    return {"ok": True}


if DIST_DIR.exists():
    app.mount("/", StaticFiles(directory=DIST_DIR, html=True), name="app")
else:

    @app.get("/")
    def root() -> dict:
        return {
            "detail": "UI not built yet. Run: cd app && npm install && npm run build, "
            "then restart this server — or use the vite dev server on :5173."
        }


if __name__ == "__main__":
    import uvicorn

    uvicorn.run(app, host="127.0.0.1", port=8001)
