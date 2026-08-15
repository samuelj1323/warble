// Warble Dictate: menu bar shell around the existing Warble backend.
//
// The renderer owns mic capture + the websocket connection to
// server/app.py's /ws?fmt=pcm16 endpoint (same pipeline the browser Live
// Mode uses). This process owns the tray icon, the global hotkey, and the
// one native capability the renderer can't do itself: simulating a paste
// keystroke into whatever app currently has focus (via nut-js), which
// requires macOS Accessibility permission for this app.

import { app, BrowserWindow, clipboard, globalShortcut, ipcMain, Menu, Tray } from 'electron';
import * as path from 'path';

const HOTKEY = 'CommandOrControl+Shift+D';

let tray: Tray | null = null;
let win: BrowserWindow | null = null;
let recording = false;

function createWindow(): void {
  win = new BrowserWindow({
    width: 380,
    height: 520,
    show: false,
    resizable: false,
    fullscreenable: false,
    title: 'Warble Dictate',
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      contextIsolation: true,
      nodeIntegration: false,
    },
  });
  win.loadFile(path.join(__dirname, 'renderer', 'index.html'));
  win.on('close', (e) => {
    // Menu bar app: closing the window just hides it, doesn't quit.
    if (!(app as any).isQuitting) {
      e.preventDefault();
      win?.hide();
    }
  });
}

function toggleWindow(): void {
  if (!win) return;
  if (win.isVisible()) win.hide();
  else {
    win.show();
    win.focus();
  }
}

function setTrayState(state: 'idle' | 'listening' | 'error'): void {
  if (!tray) return;
  const glyphs: Record<typeof state, string> = {
    idle: '\u{1F399}️',
    listening: '\u{1F534}',
    error: '⚠️',
  } as any;
  tray.setTitle(glyphs[state] ?? '');
  tray.setToolTip(`Warble Dictate — ${state}`);
}

function createTray(): void {
  tray = new Tray(path.join(__dirname, '..', 'assets', 'trayTemplate.png'));
  setTrayState('idle');
  const menu = Menu.buildFromTemplate([
    { label: 'Show window', click: () => win?.show() },
    { label: `Toggle dictation (${HOTKEY.replace('CommandOrControl', 'Cmd')})`, click: () => toggleRecording() },
    { type: 'separator' },
    {
      label: 'Quit',
      click: () => {
        (app as any).isQuitting = true;
        app.quit();
      },
    },
  ]);
  tray.setContextMenu(menu);
  tray.on('click', () => toggleWindow());
}

function toggleRecording(): void {
  win?.webContents.send('toggle-recording');
}

app.whenReady().then(() => {
  createWindow();
  createTray();

  globalShortcut.register(HOTKEY, toggleRecording);

  ipcMain.on('recording-state', (_event, state: 'idle' | 'listening' | 'error') => {
    recording = state === 'listening';
    setTrayState(state);
  });

  ipcMain.on('paste-text', async (_event, text: string) => {
    if (!text) return;
    clipboard.writeText(text);
    try {
      const { keyboard, Key } = await import('@nut-tree-fork/nut-js');
      await keyboard.pressKey(Key.LeftSuper, Key.V);
      await keyboard.releaseKey(Key.LeftSuper, Key.V);
    } catch (err) {
      console.error('[warble-dictate] paste failed — check Accessibility permission for this app', err);
    }
  });
});

app.on('window-all-closed', () => {
  // Menu bar app: stay alive with no windows open.
});

app.on('will-quit', () => {
  globalShortcut.unregisterAll();
});

// Keep the recording flag reachable for future features (e.g. quitting mid-recording).
export function isRecording(): boolean {
  return recording;
}
