import { useRef, useState } from 'react';
import { liveSocketUrl } from './api';
import { LiveBlockCard } from './LiveBlockCard';
import type { LiveBlock } from './types';

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

function newBlock(): LiveBlock {
  return { id: crypto.randomUUID(), entryIds: [], text: '', originalText: '', feedback: 'none', live: true };
}

type Phase = 'idle' | 'connecting' | 'listening' | 'error';

const STATUS_TEXT: Record<Phase, string> = {
  idle: '',
  connecting: 'Connecting…',
  listening: 'Listening — pause after speaking to finalize a line.',
  error: '',
};

type AgentEvent = { id: string; reply: string; actions: string[] };

export function LiveMode() {
  const [phase, setPhase] = useState<Phase>('idle');
  const [errorText, setErrorText] = useState('');
  const [blocks, setBlocks] = useState<LiveBlock[]>([newBlock()]);
  const [agentMode, setAgentMode] = useState(false);
  const [agentEvents, setAgentEvents] = useState<AgentEvent[]>([]);

  const streamRef = useRef<MediaStream | null>(null);
  const recorderRef = useRef<MediaRecorder | null>(null);
  const socketRef = useRef<WebSocket | null>(null);

  function appendToLiveBlock(id: string, text: string) {
    setBlocks((prev) => {
      const next = [...prev];
      const last = next[next.length - 1];
      const merged = last.text ? `${last.text} ${text}` : text;
      next[next.length - 1] = { ...last, entryIds: [...last.entryIds, id], text: merged, originalText: merged };
      return next;
    });
  }

  function startNewBlock() {
    setBlocks((prev) => {
      const last = prev[prev.length - 1];
      if (!last.live || last.entryIds.length === 0) return prev;
      const frozen = { ...last, live: false };
      return [...prev.slice(0, -1), frozen, newBlock()];
    });
  }

  async function start() {
    setPhase('connecting');
    setErrorText('');

    let stream: MediaStream;
    try {
      stream = await navigator.mediaDevices.getUserMedia({ audio: true });
    } catch (e) {
      setPhase('error');
      setErrorText(`Couldn't access the microphone: ${(e as Error).message}`);
      return;
    }
    streamRef.current = stream;

    const [mime, fmt] = pickMime();
    const url = liveSocketUrl(fmt, agentMode);
    const socket = new WebSocket(url);
    socketRef.current = socket;

    const connectTimeout = setTimeout(() => {
      if (socket.readyState !== WebSocket.OPEN) {
        console.error('[warble] WebSocket connect timed out after 6s', { url, readyState: socket.readyState });
        socket.close();
        setPhase('error');
        setErrorText('Timed out connecting to the server — check the console/network tab for details.');
      }
    }, 6000);

    socket.onopen = () => {
      clearTimeout(connectTimeout);
      const recorder = new MediaRecorder(stream, { mimeType: mime });
      recorderRef.current = recorder;
      recorder.ondataavailable = (e) => {
        if (e.data.size > 0 && socket.readyState === WebSocket.OPEN) {
          e.data.arrayBuffer().then((buf) => socket.send(buf));
        }
      };
      recorder.start(250);
      setPhase('listening');
    };

    socket.onmessage = (event) => {
      const msg = JSON.parse(event.data);
      if (msg.type === 'final') {
        appendToLiveBlock(msg.id, msg.text);
      } else if (msg.type === 'agent') {
        setAgentEvents((prev) => [...prev, { id: msg.id, reply: msg.reply, actions: msg.actions }]);
      }
    };

    socket.onerror = (event) => {
      clearTimeout(connectTimeout);
      console.error('[warble] WebSocket error', { url, event });
      setPhase('error');
      setErrorText('Connection to the server failed — check the console for details.');
    };
    socket.onclose = (event) => {
      clearTimeout(connectTimeout);
      console.error('[warble] WebSocket closed', { url, code: event.code, reason: event.reason, wasClean: event.wasClean });
      setPhase((p) => (p === 'error' ? p : 'idle'));
    };
  }

  function stop() {
    recorderRef.current?.stop();
    streamRef.current?.getTracks().forEach((t) => t.stop());
    socketRef.current?.send('stop');
    socketRef.current?.close();
    streamRef.current = null;
    recorderRef.current = null;
    setPhase('idle');
    setErrorText('');
  }

  function toggle() {
    if (phase === 'listening' || phase === 'connecting') stop();
    else start();
  }

  const buttonLabel =
    phase === 'connecting' ? 'Connecting…' : phase === 'listening' ? 'Stop listening' : 'Start listening';

  const liveBlock = blocks[blocks.length - 1];
  const canStartNewBlock = liveBlock.live && liveBlock.entryIds.length > 0;

  return (
    <div className="mode-panel">
      <div className="controls">
        <button
          className={`btn-primary btn-record${phase === 'listening' || phase === 'connecting' ? ' recording' : ''}`}
          onClick={toggle}
          disabled={phase === 'connecting'}
        >
          {buttonLabel}
        </button>
        <button className="btn-primary btn-newblock" onClick={startNewBlock} disabled={!canStartNewBlock}>
          New block
        </button>
        <label className="agent-toggle">
          <input
            type="checkbox"
            checked={agentMode}
            disabled={phase === 'listening' || phase === 'connecting'}
            onChange={(e) => setAgentMode(e.target.checked)}
          />
          Agent mode (voice commands)
        </label>
      </div>
      <div className="status">
        {phase === 'listening' && <span className="pulse-dot" />}
        {errorText || STATUS_TEXT[phase]}
      </div>

      {agentEvents.length > 0 && (
        <div className="agent-events">
          {agentEvents.map((e, i) => (
            <div key={i} className="agent-event">
              {e.actions.map((a, j) => (
                <div key={j} className="agent-action">
                  ⚡ {a}
                </div>
              ))}
              {e.reply && <div className="agent-reply">{e.reply}</div>}
            </div>
          ))}
        </div>
      )}

      <div className="term-list">
        {blocks.length === 1 && blocks[0].entryIds.length === 0 && phase === 'idle' && (
          <p className="hint">Hit start and talk — your words build up here as one block until you start a new one.</p>
        )}
        {blocks.map((block) =>
          block.live && block.entryIds.length === 0 ? null : (
            <LiveBlockCard
              key={block.id}
              block={block}
              onFeedback={(id, feedback) =>
                setBlocks((prev) => prev.map((b) => (b.id === id ? { ...b, feedback } : b)))
              }
            />
          )
        )}
      </div>
    </div>
  );
}
