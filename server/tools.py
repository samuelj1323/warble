"""Mac-control tools exposed to the agent. Kept intentionally narrow: no
arbitrary shell execution, since tool arguments originate from a voice
transcript (untrusted input)."""

import subprocess
from pathlib import Path

TOOL_SCHEMAS = [
    {
        "type": "function",
        "function": {
            "name": "open_app",
            "description": "Open a Mac application by name, e.g. 'Safari', 'Notes', 'Calculator'.",
            "parameters": {
                "type": "object",
                "properties": {
                    "name": {"type": "string", "description": "Application name as it appears in /Applications"},
                },
                "required": ["name"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "open_url",
            "description": "Open a URL in the default browser.",
            "parameters": {
                "type": "object",
                "properties": {
                    "url": {"type": "string", "description": "Full URL, e.g. https://example.com"},
                },
                "required": ["url"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "set_volume",
            "description": "Set the system output volume.",
            "parameters": {
                "type": "object",
                "properties": {
                    "level": {"type": "integer", "description": "Volume 0-100"},
                },
                "required": ["level"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "set_mute",
            "description": "Mute or unmute the system output.",
            "parameters": {
                "type": "object",
                "properties": {
                    "muted": {"type": "boolean", "description": "True to mute, false to unmute"},
                },
                "required": ["muted"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "lock_screen",
            "description": "Lock the Mac's screen immediately.",
            "parameters": {"type": "object", "properties": {}},
        },
    },
    {
        "type": "function",
        "function": {
            "name": "sleep_display",
            "description": "Turn off the display (does not sleep the whole machine).",
            "parameters": {"type": "object", "properties": {}},
        },
    },
    {
        "type": "function",
        "function": {
            "name": "take_screenshot",
            "description": "Take a screenshot and save it to the Desktop.",
            "parameters": {"type": "object", "properties": {}},
        },
    },
    {
        "type": "function",
        "function": {
            "name": "media_control",
            "description": "Control the active media player (Music, Spotify): play/pause, skip to next or previous track.",
            "parameters": {
                "type": "object",
                "properties": {
                    "action": {"type": "string", "enum": ["play_pause", "next", "previous"]},
                },
                "required": ["action"],
            },
        },
    },
]


def open_app(name: str) -> str:
    result = subprocess.run(["open", "-a", name], capture_output=True, text=True)
    if result.returncode != 0:
        return f"failed to open {name!r}: {result.stderr.strip()}"
    return f"opened {name}"


def open_url(url: str) -> str:
    if not (url.startswith("http://") or url.startswith("https://")):
        url = "https://" + url
    result = subprocess.run(["open", url], capture_output=True, text=True)
    if result.returncode != 0:
        return f"failed to open {url!r}: {result.stderr.strip()}"
    return f"opened {url}"


def _osascript(script: str) -> subprocess.CompletedProcess:
    return subprocess.run(["osascript", "-e", script], capture_output=True, text=True)


def set_volume(level: int) -> str:
    level = max(0, min(100, int(level)))
    result = _osascript(f"set volume output volume {level}")
    if result.returncode != 0:
        return f"failed to set volume: {result.stderr.strip()}"
    return f"volume set to {level}"


def set_mute(muted: bool) -> str:
    result = _osascript(f"set volume output muted {'true' if muted else 'false'}")
    if result.returncode != 0:
        return f"failed to {'mute' if muted else 'unmute'}: {result.stderr.strip()}"
    return "muted" if muted else "unmuted"


def lock_screen() -> str:
    result = subprocess.run(
        ["osascript", "-e", 'tell application "System Events" to keystroke "q" using {control down, command down}'],
        capture_output=True, text=True,
    )
    if result.returncode != 0:
        return f"failed to lock screen: {result.stderr.strip()}"
    return "locked screen"


def sleep_display() -> str:
    result = subprocess.run(["pmset", "displaysleepnow"], capture_output=True, text=True)
    if result.returncode != 0:
        return f"failed to sleep display: {result.stderr.strip()}"
    return "display sleeping"


def take_screenshot() -> str:
    from datetime import datetime

    path = Path.home() / "Desktop" / f"warble-screenshot-{datetime.now():%Y%m%d-%H%M%S}.png"
    result = subprocess.run(["screencapture", "-x", str(path)], capture_output=True, text=True)
    if result.returncode != 0:
        return f"failed to take screenshot: {result.stderr.strip()}"
    return f"screenshot saved to {path}"


_MEDIA_VERBS = {"play_pause": "playpause", "next": "next track", "previous": "previous track"}


def media_control(action: str) -> str:
    verb = _MEDIA_VERBS.get(action)
    if verb is None:
        return f"unknown media action: {action}"

    for player in ("Spotify", "Music"):
        running = _osascript(f'application "{player}" is running')
        if running.returncode == 0 and running.stdout.strip() == "true":
            result = _osascript(f'tell application "{player}" to {verb}')
            if result.returncode != 0:
                return f"failed to {action} on {player}: {result.stderr.strip()}"
            return f"{action} on {player}"

    return "no supported media player (Spotify/Music) is running"


DISPATCH = {
    "open_app": open_app,
    "open_url": open_url,
    "set_volume": set_volume,
    "set_mute": set_mute,
    "lock_screen": lock_screen,
    "sleep_display": sleep_display,
    "take_screenshot": take_screenshot,
    "media_control": media_control,
}
