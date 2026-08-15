"""Live transcription sessions.

The browser streams MediaRecorder chunks (webm/opus) over a WebSocket. We pipe
them through ffmpeg to get 16 kHz mono PCM, endpoint utterances with Silero VAD
(speech followed by ~0.7 s of silence), and hand each finished utterance to the
transcription callback.
"""

import asyncio
from collections.abc import Awaitable, Callable

import numpy as np
from faster_whisper.vad import VadOptions, get_speech_timestamps

SAMPLE_RATE = 16000
BYTES_PER_SAMPLE = 2  # s16le mono
TICK_S = 0.25
TRAILING_SILENCE_S = 0.7
MAX_UTTERANCE_S = 15.0  # force-cut long monologues at the last VAD boundary
MIN_SPEECH_S = 0.4
PAD_AFTER_CUT_S = 0.1

VAD_OPTIONS = VadOptions(
    threshold=0.5,
    min_speech_duration_ms=250,
    min_silence_duration_ms=int(TRAILING_SILENCE_S * 1000),
    speech_pad_ms=100,
)

# pcm int16 ndarray -> coroutine
UtteranceCallback = Callable[[np.ndarray], Awaitable[None]]


class LiveSession:
    def __init__(self, on_utterance: UtteranceCallback, container: str = "webm"):
        self.on_utterance = on_utterance
        self.container = container if container in ("webm", "mp4", "pcm16") else "webm"
        self.buffer = bytearray()
        self.proc = None
        self._reader = None
        self._segmenter = None
        self._tail = b""
        self._closed = False

    async def start(self) -> None:
        if self.container == "pcm16":
            # Client already sends raw 16 kHz mono s16le — skip ffmpeg entirely.
            self._segmenter = asyncio.create_task(self._segment_loop())
            return
        self.proc = await asyncio.create_subprocess_exec(
            "ffmpeg", "-v", "error", "-f", self.container, "-i", "pipe:0",
            "-f", "s16le", "-ac", "1", "-ar", str(SAMPLE_RATE), "pipe:1",
            stdin=asyncio.subprocess.PIPE,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.DEVNULL,
        )
        self._reader = asyncio.create_task(self._read_pcm())
        self._segmenter = asyncio.create_task(self._segment_loop())

    async def feed(self, data: bytes) -> None:
        if self._closed:
            return
        if self.container == "pcm16":
            self.buffer.extend(data)
            return
        if not self.proc:
            return
        try:
            self.proc.stdin.write(data)
            await self.proc.stdin.drain()
        except (BrokenPipeError, ConnectionResetError):
            self._closed = True

    async def finish(self) -> None:
        """Client disconnected: flush ffmpeg, then emit any trailing utterance."""
        self._closed = True
        if self.proc and self.proc.stdin:
            try:
                self.proc.stdin.close()
            except (BrokenPipeError, ConnectionResetError):
                pass
            await self.proc.wait()
        if self._reader:
            await self._reader
        if self._segmenter:
            self._segmenter.cancel()
        await self._flush_remaining()

    async def _read_pcm(self) -> None:
        while True:
            chunk = await self.proc.stdout.read(65536)
            if not chunk:
                break
            data = self._tail + chunk
            if len(data) % 2:
                data, self._tail = data[:-1], data[-1:]
            else:
                self._tail = b""
            self.buffer.extend(data)

    async def _segment_loop(self) -> None:
        while True:
            await asyncio.sleep(TICK_S)
            await self._maybe_cut()

    def _speech_bounds(self) -> dict | None:
        pcm = np.frombuffer(bytes(self.buffer), dtype=np.int16)
        if len(pcm) < SAMPLE_RATE // 2:
            return None
        audio = pcm.astype(np.float32) / 32768.0
        segments = get_speech_timestamps(audio, VAD_OPTIONS)
        if not segments:
            return None
        last_end = segments[-1]["end"]
        return {
            "start": segments[0]["start"],
            "end": last_end,
            "trailing_s": (len(pcm) - last_end) / SAMPLE_RATE,
            "speech_s": sum(s["end"] - s["start"] for s in segments) / SAMPLE_RATE,
        }

    async def _maybe_cut(self) -> None:
        if not self.buffer:
            return
        bounds = self._speech_bounds()
        if bounds is None:
            # pure silence so far — don't let the buffer grow forever
            max_keep = 2 * SAMPLE_RATE * BYTES_PER_SAMPLE
            if len(self.buffer) > 10 * SAMPLE_RATE * BYTES_PER_SAMPLE:
                del self.buffer[:-max_keep]
            return
        ready = bounds["trailing_s"] >= TRAILING_SILENCE_S
        too_long = bounds["end"] / SAMPLE_RATE >= MAX_UTTERANCE_S
        if not (ready or too_long):
            return
        if bounds["speech_s"] < MIN_SPEECH_S:
            del self.buffer[: bounds["end"] * BYTES_PER_SAMPLE]  # noise blip — drop
            return
        await self._emit(bounds["end"])

    async def _flush_remaining(self) -> None:
        bounds = self._speech_bounds()
        if bounds and bounds["speech_s"] >= MIN_SPEECH_S:
            await self._emit(bounds["end"])
        self.buffer.clear()

    async def _emit(self, speech_end_sample: int) -> None:
        cut = speech_end_sample + int(PAD_AFTER_CUT_S * SAMPLE_RATE)
        cut_bytes = min(cut * BYTES_PER_SAMPLE, len(self.buffer))
        pcm = np.frombuffer(bytes(self.buffer[:cut_bytes]), dtype=np.int16).copy()
        del self.buffer[:cut_bytes]
        await self.on_utterance(pcm)
