import { contextBridge, ipcRenderer } from "electron";

import type { HumeAudioEvent, MemoryFactInput, RockyApi, SpreadsheetSpec, TranscriptEntry } from "../shared/types";
import type { RockyStyleFailure } from "../shared/rockyStyle";

const rockyApi: RockyApi = {
  getConfig: () => ipcRenderer.invoke("rocky:get-config"),
  createRealtimeSession: () => ipcRenderer.invoke("rocky:create-realtime-session"),
  startTranscript: () => ipcRenderer.invoke("rocky:start-transcript"),
  appendTranscript: (entry: TranscriptEntry) => ipcRenderer.invoke("rocky:append-transcript", entry),
  recordStyleFailure: (failure: RockyStyleFailure) => ipcRenderer.invoke("rocky:record-style-failure", failure),
  rememberFamilyFact: (input: MemoryFactInput) => ipcRenderer.invoke("rocky:remember-family-fact", input),
  createSpreadsheet: (spec: SpreadsheetSpec, sessionId?: string) =>
    ipcRenderer.invoke("rocky:create-spreadsheet", spec, sessionId),
  updateActiveSpreadsheet: (spec: SpreadsheetSpec, sessionId?: string) =>
    ipcRenderer.invoke("rocky:update-active-spreadsheet", spec, sessionId),
  openSpreadsheet: (filePath: string) => ipcRenderer.invoke("rocky:open-spreadsheet", filePath),
  revealSpreadsheet: (filePath: string) => ipcRenderer.invoke("rocky:reveal-spreadsheet", filePath),
  speakWithHume: (sessionId: string, text: string, flush?: boolean) => ipcRenderer.invoke(
    "rocky:hume-speak",
    sessionId,
    text,
    flush,
  ),
  cancelHumeSpeech: (sessionId: string) => ipcRenderer.invoke("rocky:hume-cancel", sessionId),
  onHumeAudio: (listener: (sessionId: string, event: HumeAudioEvent) => void) => {
    const handler = (_event: Electron.IpcRendererEvent, sessionId: string, event: HumeAudioEvent): void => {
      listener(sessionId, event);
    };
    ipcRenderer.on("rocky:hume-audio", handler);
    return () => ipcRenderer.removeListener("rocky:hume-audio", handler);
  },
};

contextBridge.exposeInMainWorld("rocky", rockyApi);
