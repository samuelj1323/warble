export async function submitFeedback(id: string, correctedText: string | null, rating: string | null): Promise<void> {
  const res = await fetch('/feedback', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ id, corrected_text: correctedText, rating }),
  });
  if (!res.ok) {
    const data = await res.json().catch(() => ({}));
    throw new Error(data.detail ?? 'feedback failed');
  }
}

export function liveSocketUrl(fmt: string): string {
  const proto = location.protocol === 'https:' ? 'wss:' : 'ws:';
  return `${proto}//${location.host}/ws?fmt=${fmt}`;
}
