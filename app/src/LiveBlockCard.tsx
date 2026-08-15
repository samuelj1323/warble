import { useEffect, useState } from 'react';
import { submitFeedback } from './api';
import type { LiveBlock } from './types';

interface Props {
  block: LiveBlock;
  onFeedback: (id: string, feedback: LiveBlock['feedback']) => void;
}

export function LiveBlockCard({ block, onFeedback }: Props) {
  const [text, setText] = useState(block.text);
  const [busy, setBusy] = useState(false);
  const [copied, setCopied] = useState(false);
  const dirty = text !== block.text;

  // While the block is still live, block.text keeps growing as new utterances
  // land — keep the local (editable) copy in sync until it freezes.
  useEffect(() => {
    if (block.live) setText(block.text);
  }, [block.text, block.live]);
  const singleUtterance = block.entryIds.length === 1;

  async function copy() {
    await navigator.clipboard.writeText(text);
    setCopied(true);
    setTimeout(() => setCopied(false), 1200);
  }

  async function markCorrect() {
    setBusy(true);
    try {
      await Promise.all(block.entryIds.map((id) => submitFeedback(id, null, 'correct')));
      onFeedback(block.id, 'correct');
    } finally {
      setBusy(false);
    }
  }

  async function saveCorrection() {
    if (!singleUtterance) return;
    setBusy(true);
    try {
      await submitFeedback(block.entryIds[0], text, null);
      onFeedback(block.id, 'corrected');
    } finally {
      setBusy(false);
    }
  }

  return (
    <div className={`term-block${block.live ? ' term-block-live' : ''}`}>
      <div className="term-block-head">
        <span className="term-block-label">block {block.entryIds.length ? `· ${block.entryIds.length} line${block.entryIds.length > 1 ? 's' : ''}` : ''}</span>
        <div className="term-block-actions">
          <button className="btn-icon" onClick={copy} title="Copy text">
            {copied ? 'Copied' : 'Copy'}
          </button>
          {block.feedback === 'correct' && <span className="badge badge-correct">Marked correct</span>}
          {block.feedback === 'corrected' && <span className="badge badge-corrected">Correction saved</span>}
          {block.feedback === 'none' && block.entryIds.length > 0 && (
            <>
              <button className="btn-ghost" disabled={busy} onClick={markCorrect}>
                Correct
              </button>
              {!block.live && singleUtterance && (
                <button className="btn-ghost" disabled={busy || !dirty} onClick={saveCorrection}>
                  Save fix
                </button>
              )}
            </>
          )}
        </div>
      </div>
      {block.live ? (
        <p className="term-block-text">
          {text}
          <span className="term-cursor" />
        </p>
      ) : (
        <textarea
          className="term-block-text term-block-editable"
          spellCheck={false}
          value={text}
          onChange={(e) => setText(e.target.value)}
          rows={Math.min(12, Math.max(2, Math.ceil(text.length / 60)))}
        />
      )}
    </div>
  );
}
