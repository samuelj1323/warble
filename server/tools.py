"""Mac-control tools exposed to the agent. Kept intentionally narrow: no
arbitrary shell execution, since tool arguments originate from a voice
transcript (untrusted input)."""

import subprocess

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


DISPATCH = {
    "open_app": open_app,
    "open_url": open_url,
}
