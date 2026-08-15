"""System-wide dictation: press a hotkey, talk, and the transcribed text gets
pasted into whatever app has focus (Messages, Claude desktop, a text field —
anything that accepts Cmd+V).

Talks straight to the existing Warble backend's /ws endpoint (server/app.py) —
no browser involved. Captures the mic directly, streams raw 16 kHz PCM
(fmt=pcm16, see server/streaming.py), and on each finalized utterance:
  1. copies the text to the clipboard (pbcopy)
  2. simulates Cmd+V into the focused app

Requires macOS Accessibility permission for whatever process runs this
(Terminal/iTerm/python) — System Settings > Privacy & Security >
Accessibility — so it can simulate the paste keystroke.

Run:  .venv/bin/python native/dictate.py
Toggle recording:  Cmd+Shift+D (see HOTKEY below)
Quit:               Ctrl+C in the terminal
"""

import asyncio
import queue
import subprocess
import sys
import threading

import numpy as np
import sounddevice as sd
import websockets
from pynput import keyboard

SERVER_URL = "ws://127.0.0.1:8001/ws?fmt=pcm16"
SAMPLE_RATE = 16000
HOTKEY = "<cmd>+<shift>+d"


def notify(message: str) -> None:
    print(f"[dictate] {message}")
    try:
        subprocess.run(
            ["osascript", "-e", f'display notification "{message}" with title "Warble Dictate"'],
            check=False,
            capture_output=True,
        )
    except FileNotFoundError:
        pass


def paste_text(text: str) -> None:
    if not text:
        return
    subprocess.run(["pbcopy"], input=text.encode("utf-8"), check=True)
    controller = keyboard.Controller()
    with controller.pressed(keyboard.Key.cmd):
        controller.press("v")
        controller.release("v")


class Dictator:
    def __init__(self) -> None:
        self.loop: asyncio.AbstractEventLoop | None = None
        self.recording = False
        self._audio_q: "queue.Queue[bytes]" = queue.Queue()
        self._stream: sd.RawInputStream | None = None
        self._ws_task: asyncio.Task | None = None
        self._stop_ws = asyncio.Event()

    def toggle(self) -> None:
        if self.loop is None:
            return
        asyncio.run_coroutine_threadsafe(self._toggle(), self.loop)

    async def _toggle(self) -> None:
        if self.recording:
            await self._stop()
        else:
            await self._start()

    async def _start(self) -> None:
        self.recording = True
        notify("listening…")
        self._stop_ws.clear()
        self._ws_task = asyncio.create_task(self._run())

    async def _stop(self) -> None:
        self.recording = False
        self._stop_ws.set()
        if self._ws_task:
            await self._ws_task
        notify("stopped")

    def _on_audio(self, indata, frames, time_info, status) -> None:
        if status:
            print(f"[dictate] mic status: {status}", file=sys.stderr)
        self._audio_q.put(bytes(indata))

    async def _run(self) -> None:
        try:
            self._stream = sd.RawInputStream(
                samplerate=SAMPLE_RATE, channels=1, dtype="int16",
                blocksize=4000, callback=self._on_audio,
            )
            self._stream.start()
        except Exception as e:
            notify(f"mic error: {e}")
            self.recording = False
            return

        try:
            async with websockets.connect(SERVER_URL, max_size=None) as ws:
                sender = asyncio.create_task(self._send_audio(ws))
                receiver = asyncio.create_task(self._recv_final(ws))
                await self._stop_ws.wait()
                sender.cancel()
                try:
                    await ws.send("stop")
                except Exception:
                    pass
                await receiver
        except Exception as e:
            notify(f"connection error: {e}")
        finally:
            if self._stream:
                self._stream.stop()
                self._stream.close()
                self._stream = None
            with self._audio_q.mutex:
                self._audio_q.queue.clear()

    async def _send_audio(self, ws) -> None:
        loop = asyncio.get_running_loop()
        try:
            while True:
                chunk = await loop.run_in_executor(None, self._audio_q.get)
                await ws.send(chunk)
        except asyncio.CancelledError:
            pass

    async def _recv_final(self, ws) -> None:
        async for message in ws:
            if isinstance(message, str):
                import json

                msg = json.loads(message)
                if msg.get("type") == "final" and msg.get("text"):
                    print(f"[dictate] -> {msg['text']}")
                    paste_text(msg["text"])


def main() -> None:
    dictator = Dictator()

    async def run() -> None:
        dictator.loop = asyncio.get_running_loop()
        await asyncio.Event().wait()  # run forever

    def on_hotkey() -> None:
        dictator.toggle()

    listener = keyboard.GlobalHotKeys({HOTKEY: on_hotkey})
    listener.daemon = True
    listener.start()

    print(f"[dictate] ready — press {HOTKEY} to start/stop dictating anywhere.")
    print("[dictate] make sure Terminal/Python has Accessibility + Microphone permission")
    print("[dictate] (System Settings > Privacy & Security).")

    try:
        asyncio.run(run())
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
