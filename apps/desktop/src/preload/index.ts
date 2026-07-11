import { contextBridge, ipcRenderer } from "electron";

import type { RockyApi, SpreadsheetSpec, TranscriptEntry } from "../shared/types";
import type { RockyStyleFailure } from "../shared/rockyStyle";

const rockyApi: RockyApi = {
  getConfig: () => ipcRenderer.invoke("rocky:get-config"),
  createRealtimeSession: () => ipcRenderer.invoke("rocky:create-realtime-session"),
  startTranscript: () => ipcRenderer.invoke("rocky:start-transcript"),
  appendTranscript: (entry: TranscriptEntry) => ipcRenderer.invoke("rocky:append-transcript", entry),
  recordStyleFailure: (failure: RockyStyleFailure) => ipcRenderer.invoke("rocky:record-style-failure", failure),
  createSpreadsheet: (spec: SpreadsheetSpec, sessionId?: string) =>
    ipcRenderer.invoke("rocky:create-spreadsheet", spec, sessionId),
  openSpreadsheet: (filePath: string) => ipcRenderer.invoke("rocky:open-spreadsheet", filePath),
  revealSpreadsheet: (filePath: string) => ipcRenderer.invoke("rocky:reveal-spreadsheet", filePath),
};

contextBridge.exposeInMainWorld("rocky", rockyApi);
