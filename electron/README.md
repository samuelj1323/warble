# Warble Dictate (Electron)

Menu bar dictation client. Replaces `native/dictate.py` — talks to the same
`server/app.py` backend over `/ws`, no server changes needed.

- Mic capture + websocket streaming: renderer (`src/renderer/renderer.ts`), via `MediaRecorder`
  (webm/opus) — same capture path as the browser Live Mode and the training-data recorder, so
  transcription quality matches. (An earlier version streamed raw PCM through a manually
  resampled `AudioContext`/`ScriptProcessorNode` — noticeably worse transcriptions, since it
  diverged from the capture path the model's training data and Live Mode both use.)
- Tray icon, global hotkey (⌘⇧D), window lifecycle: main process (`src/main.ts`).
- Paste-into-focused-app: main process, via `@nut-tree-fork/nut-js` + Electron's clipboard.

## Setup

```
cd electron
npm install
npm start          # builds TS then launches electron
```

Start the backend first: `.venv/bin/python server/app.py` (from repo root).

## Permissions (macOS)

First run will need, granted to this Electron app specifically (not Terminal):
- **Microphone** — prompted automatically on first `getUserMedia` call.
- **Accessibility** — required for the simulated Cmd+V paste; add manually via
  System Settings > Privacy & Security > Accessibility if the paste silently
  fails (check the terminal running `npm start` for a permission error).

## Notes / next steps

- Hotkey is hardcoded (`HOTKEY` in `main.ts`) — no settings UI for it yet.
- No packaging/signing set up (`electron-builder` etc.) — this is a dev scaffold, run via `npm start`.
- Command-mode (voice commands vs. plain dictation) isn't implemented — `renderer.ts`'s
  `socket.onmessage` handler is the place to add intent-matching before deciding
  paste vs. some other action.
