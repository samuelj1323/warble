export {};

declare global {
  interface Window {
    warble: {
      onToggleRecording: (cb: () => void) => void;
      reportState: (state: 'idle' | 'listening' | 'error') => void;
      pasteText: (text: string) => void;
    };
  }
}
