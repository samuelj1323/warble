// Mic capture + websocket streaming to the existing Warble backend
// (server/app.py's /ws endpoint). Uses MediaRecorder -> webm/opus, same as
// the browser Live Mode (app/src/LiveMode.tsx) and the same capture method
// used to record the fine-tuning data (recorder/static/index.html) — plain
// `getUserMedia({ audio: true })`, no forced sample rate/resampling on our
// end. An earlier version captured raw PCM via a manually-resampled
// AudioContext/ScriptProcessorNode and produced noticeably worse
// transcriptions than Live Mode; matching Live Mode's proven capture path
// fixed it.
//
// Runs in the renderer because only the renderer has getUserMedia; the one
// piece that needs Node/native access (simulating the paste keystroke) is
// delegated to the main process via window.warble.pasteText.

const MIME_CANDIDATES: [string, string][] = [
  ['audio/webm', 'webm'],
  ['audio/mp4', 'mp4'],
];

function pickMime(): [string, string] {
  for (const [mime, fmt] of MIME_CANDIDATES) {
    if (MediaRecorder.isTypeSupported(mime)) return [mime, fmt];
  }
  return MIME_CANDIDATES[0];
}

const statusDot = document.getElementById('status-dot') as HTMLDivElement;
const statusText = document.getElementById('status-text') as HTMLDivElement;
const toggleBtn = document.getElementById('toggle-btn') as HTMLButtonElement;
const historyEl = document.getElementById('history') as HTMLDivElement;
const serverUrlInput = document.getElementById('server-url') as HTMLInputElement;

const STORAGE_KEY = 'warble-dictate:server-url';
const savedUrl = localStorage.getItem(STORAGE_KEY);
if (savedUrl) serverUrlInput.value = savedUrl;
serverUrlInput.addEventListener('change', () => {
  localStorage.setItem(STORAGE_KEY, serverUrlInput.value);
});

type Phase = 'idle' | 'listening' | 'error';
let phase: Phase = 'idle';

let stream: MediaStream | null = null;
let recorder: MediaRecorder | null = null;
let socket: WebSocket | null = null;

function setPhase(next: Phase, detail?: string): void {
  phase = next;
  statusDot.className = `dot ${next}`;
  statusText.textContent = detail ?? { idle: 'Idle', listening: 'Listening…', error: 'Error' }[next];
  toggleBtn.textContent = next === 'listening' ? 'Stop dictating (⌘⇧D)' : 'Start dictating (⌘⇧D)';
  toggleBtn.classList.toggle('listening', next === 'listening');
  window.warble.reportState(next);
}

function appendHistory(text: string): void {
  const hint = historyEl.querySelector('.hint');
  if (hint) hint.remove();
  const line = document.createElement('div');
  line.className = 'line';
  const ts = document.createElement('span');
  ts.className = 'ts';
  ts.textContent = new Date().toLocaleTimeString();
  line.appendChild(ts);
  line.appendChild(document.createTextNode(text));
  historyEl.appendChild(line);
  historyEl.scrollTop = historyEl.scrollHeight;
}

function serverUrlFor(fmt: string): string {
  const base = serverUrlInput.value.trim();
  const url = new URL(base);
  url.searchParams.set('fmt', fmt);
  return url.toString();
}

async function start(): Promise<void> {
  try {
    stream = await navigator.mediaDevices.getUserMedia({ audio: true });
  } catch (e) {
    setPhase('error', `Mic access denied: ${(e as Error).message}`);
    return;
  }

  const [mime, fmt] = pickMime();
  socket = new WebSocket(serverUrlFor(fmt));

  socket.onopen = () => {
    recorder = new MediaRecorder(stream!, { mimeType: mime });
    recorder.ondataavailable = (e) => {
      if (e.data.size > 0 && socket?.readyState === WebSocket.OPEN) {
        e.data.arrayBuffer().then((buf) => socket?.send(buf));
      }
    };
    recorder.start(250);
    setPhase('listening');
  };

  socket.onmessage = (event) => {
    const msg = JSON.parse(event.data);
    if (msg.type === 'final' && msg.text) {
      appendHistory(msg.text);
      window.warble.pasteText(msg.text);
    }
  };

  socket.onerror = () => setPhase('error', 'Connection failed — is server/app.py running?');
  socket.onclose = () => {
    if (phase !== 'error') setPhase('idle');
  };
}

function stop(): void {
  recorder?.stop();
  recorder = null;
  socket?.send('stop');
  socket?.close();
  socket = null;
  stream?.getTracks().forEach((t) => t.stop());
  stream = null;
  setPhase('idle');
}

function toggle(): void {
  if (phase === 'listening') stop();
  else start();
}

toggleBtn.addEventListener('click', toggle);
window.warble.onToggleRecording(toggle);
