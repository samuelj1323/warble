"""Routes a transcript through OpenRouter with tool-calling enabled, executes
any tool calls locally, and returns a summary of what happened.

Accepts an optional `on_event` callback so callers (the /ws handler) can
stream progress — thinking / calling a tool / tool result / composing reply —
to the client as it happens, instead of the client seeing nothing until the
whole (multi-round-trip) run finishes."""

import json
import os
from typing import Awaitable, Callable, Optional

import httpx

from tools import DISPATCH, TOOL_SCHEMAS

OPENROUTER_URL = "https://openrouter.ai/api/v1/chat/completions"
MODEL = os.environ.get("WARBLE_AGENT_MODEL", "moonshotai/kimi-k2")

SYSTEM_PROMPT = (
    "You control a Mac via voice transcripts. If the user's message describes "
    "an action you have a tool for, call the tool. Otherwise reply briefly in "
    "plain text. Never explain what you're about to do before calling a tool."
)

EventCallback = Optional[Callable[[dict], Awaitable[None]]]


async def run_agent(transcript: str, on_event: EventCallback = None) -> dict:
    """Returns {"reply": str, "actions": [str, ...]}."""

    async def emit(event: dict) -> None:
        if on_event:
            await on_event(event)

    api_key = os.environ.get("OPENROUTER_API_KEY")
    if not api_key:
        return {"reply": "OPENROUTER_API_KEY not set", "actions": []}

    messages = [
        {"role": "system", "content": SYSTEM_PROMPT},
        {"role": "user", "content": transcript},
    ]

    await emit({"type": "agent_thinking"})

    async with httpx.AsyncClient(timeout=30) as client:
        resp = await client.post(
            OPENROUTER_URL,
            headers={"Authorization": f"Bearer {api_key}"},
            json={"model": MODEL, "messages": messages, "tools": TOOL_SCHEMAS},
        )
        resp.raise_for_status()
        data = resp.json()

    message = data["choices"][0]["message"]
    tool_calls = message.get("tool_calls") or []
    actions: list[str] = []

    if not tool_calls:
        return {"reply": message.get("content") or "", "actions": actions}

    messages.append(message)
    for call in tool_calls:
        fn_name = call["function"]["name"]
        try:
            args = json.loads(call["function"]["arguments"] or "{}")
        except json.JSONDecodeError:
            args = {}

        await emit({"type": "agent_tool_call", "name": fn_name, "args": args})

        handler = DISPATCH.get(fn_name)
        result = handler(**args) if handler else f"unknown tool: {fn_name}"
        actions.append(result)

        await emit({"type": "agent_tool_result", "name": fn_name, "result": result})

        messages.append(
            {
                "role": "tool",
                "tool_call_id": call["id"],
                "content": result,
            }
        )

    await emit({"type": "agent_replying"})

    async with httpx.AsyncClient(timeout=30) as client:
        resp = await client.post(
            OPENROUTER_URL,
            headers={"Authorization": f"Bearer {api_key}"},
            json={"model": MODEL, "messages": messages, "tools": TOOL_SCHEMAS},
        )
        resp.raise_for_status()
        followup = resp.json()["choices"][0]["message"].get("content") or ""

    return {"reply": followup, "actions": actions}
