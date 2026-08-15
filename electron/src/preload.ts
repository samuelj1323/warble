import { contextBridge, ipcRenderer } from 'electron';

contextBridge.exposeInMainWorld('warble', {
  onToggleRecording: (cb: () => void) => {
    ipcRenderer.on('toggle-recording', cb);
  },
  reportState: (state: 'idle' | 'listening' | 'error') => {
    ipcRenderer.send('recording-state', state);
  },
  pasteText: (text: string) => {
    ipcRenderer.send('paste-text', text);
  },
});
