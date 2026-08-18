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
const agentCheckbox = document.getElementById('agent-checkbox') as HTMLInputElement;
const activityBanner = document.getElementById('activity-banner') as HTMLDivElement;
const activityText = document.getElementById('activity-text') as HTMLDivElement;

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
  agentCheckbox.disabled = next === 'listening';
  window.warble.reportState(next);
}

type HistoryKind = 'line' | 'agent-action' | 'agent-error' | 'agent-tool' | 'agent-tool pending';

function appendHistory(text: string, kind: HistoryKind = 'line', spinner = false): HTMLDivElement {
  const hint = historyEl.querySelector('.hint');
  if (hint) hint.remove();
  const line = document.createElement('div');
  line.className = kind === 'line' ? 'line' : `line ${kind}`;
  const ts = document.createElement('span');
  ts.className = 'ts';
  ts.textContent = new Date().toLocaleTimeString();
  line.appendChild(ts);
  if (spinner) {
    const spin = document.createElement('span');
    spin.className = 'spinner-sm';
    line.appendChild(spin);
  }
  const body = document.createElement('span');
  body.className = 'body';
  body.textContent = text;
  line.appendChild(body);
  historyEl.appendChild(line);
  historyEl.scrollTop = historyEl.scrollHeight;
  return line;
}

// Tracks the in-flight tool-call line (agent.py runs tool calls one at a
// time, so at most one is ever pending) so its result can update it in
// place rather than appending a second, disconnected line.
let pendingToolEl: HTMLDivElement | null = null;

// One prominent, always-in-the-same-place banner for "something is
// happening" — replaces the old header badge, which was easy to miss.
// `mode` picks the color: 'busy' (blue, default), 'skill' (purple, a tool
// is actively being pulled/run), 'done' (green flash, spinner hidden).
function setActivity(text: string | null, mode: 'busy' | 'skill' | 'done' = 'busy'): void {
  if (!text) {
    activityBanner.classList.add('hidden');
    return;
  }
  activityText.textContent = text;
  activityBanner.classList.remove('hidden', 'skill', 'done');
  if (mode !== 'busy') activityBanner.classList.add(mode);
}

let doneTimer: ReturnType<typeof setTimeout> | null = null;

function flashDone(text: string): void {
  if (doneTimer) clearTimeout(doneTimer);
  setActivity(text, 'done');
  doneTimer = setTimeout(() => setActivity(null), 900);
}

function handleAgentEvent(msg: any): void {
  switch (msg.type) {
    case 'transcribing':
      setActivity('📝 Transcribing…', 'busy');
      break;
    case 'agent_thinking':
      setActivity('🤖 Thinking…', 'busy');
      break;
    case 'agent_tool_call': {
      const argStr = msg.args && Object.keys(msg.args).length ? JSON.stringify(msg.args) : '';
      setActivity(`🔧 Pulling skill: ${msg.name}…`, 'skill');
      pendingToolEl = appendHistory(`${msg.name}${argStr ? ' ' + argStr : ''}`, 'agent-tool pending', true);
      break;
    }
    case 'agent_tool_result': {
      flashDone(`✅ ${msg.name} done`);
      if (pendingToolEl) {
        pendingToolEl.className = 'line agent-tool';
        pendingToolEl.querySelector('.spinner-sm')?.remove();
        const body = pendingToolEl.querySelector('.body');
        if (body) body.textContent = `✅ ${msg.result}`;
        pendingToolEl = null;
      } else {
        appendHistory(`✅ ${msg.result}`, 'agent-tool');
      }
      break;
    }
    case 'agent_replying':
      setActivity('💬 Composing reply…', 'busy');
      break;
    case 'agent': {
      if (doneTimer) clearTimeout(doneTimer);
      setActivity(null);
      const isError = typeof msg.reply === 'string' && msg.reply.startsWith('agent error:');
      if (msg.reply) appendHistory(msg.reply, isError ? 'agent-error' : 'agent-action');
      break;
    }
  }
}

function serverUrlFor(fmt: string): string {
  const base = serverUrlInput.value.trim();
  const url = new URL(base);
  url.searchParams.set('fmt', fmt);
  url.searchParams.set('agent', String(agentCheckbox.checked));
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
      if (!agentCheckbox.checked) setActivity(null); // agent mode keeps the banner going into agent_thinking
      appendHistory(msg.text);
      if (!agentCheckbox.checked) window.warble.pasteText(msg.text);
    } else if (msg.type === 'transcribing' || (typeof msg.type === 'string' && msg.type.startsWith('agent'))) {
      handleAgentEvent(msg);
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
  setActivity(null);
  pendingToolEl = null;
}

function toggle(): void {
  if (phase === 'listening') stop();
  else start();
}

toggleBtn.addEventListener('click', toggle);
window.warble.onToggleRecording(toggle);
