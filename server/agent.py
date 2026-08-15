"""Routes a transcript through OpenRouter with tool-calling enabled, executes
any tool calls locally, and returns a summary of what happened."""

import json
import os

import httpx

from tools import DISPATCH, TOOL_SCHEMAS

OPENROUTER_URL = "https://openrouter.ai/api/v1/chat/completions"
MODEL = os.environ.get("WARBLE_AGENT_MODEL", "openai/gpt-oss-20b:free")

SYSTEM_PROMPT = (
    "You control a Mac via voice transcripts. If the user's message describes "
    "an action you have a tool for, call the tool. Otherwise reply briefly in "
    "plain text. Never explain what you're about to do before calling a tool."
)


async def run_agent(transcript: str) -> dict:
    """Returns {"reply": str, "actions": [str, ...]}."""
    api_key = os.environ.get("OPENROUTER_API_KEY")
    if not api_key:
        return {"reply": "OPENROUTER_API_KEY not set", "actions": []}

    messages = [
        {"role": "system", "content": SYSTEM_PROMPT},
        {"role": "user", "content": transcript},
    ]

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

        handler = DISPATCH.get(fn_name)
        result = handler(**args) if handler else f"unknown tool: {fn_name}"
        actions.append(result)

        messages.append(
            {
                "role": "tool",
                "tool_call_id": call["id"],
                "content": result,
            }
        )

    async with httpx.AsyncClient(timeout=30) as client:
        resp = await client.post(
            OPENROUTER_URL,
            headers={"Authorization": f"Bearer {api_key}"},
            json={"model": MODEL, "messages": messages, "tools": TOOL_SCHEMAS},
        )
        resp.raise_for_status()
        followup = resp.json()["choices"][0]["message"].get("content") or ""

    return {"reply": followup, "actions": actions}
