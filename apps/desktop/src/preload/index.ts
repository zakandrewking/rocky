import { contextBridge, ipcRenderer } from "electron";

import type {
  BackgroundResearchInput,
  BackgroundResearchResult,
  DebugLogEntry,
  HumeAudioEvent,
  HowToDocSpec,
  MemoryFactInput,
  RockyApi,
  SpreadsheetEditSpec,
  SpreadsheetSpec,
  TranscriptEntry,
} from "../shared/types";
import type { RockyStyleFailure } from "../shared/rockyStyle";

const rockyApi: RockyApi = {
  getConfig: () => ipcRenderer.invoke("rocky:get-config"),
  createRealtimeSession: () => ipcRenderer.invoke("rocky:create-realtime-session"),
  startTranscript: () => ipcRenderer.invoke("rocky:start-transcript"),
  appendTranscript: (entry: TranscriptEntry) => ipcRenderer.invoke("rocky:append-transcript", entry),
  appendDebugLog: (entry: DebugLogEntry) => ipcRenderer.invoke("rocky:append-debug-log", entry),
  recordStyleFailure: (failure: RockyStyleFailure) => ipcRenderer.invoke("rocky:record-style-failure", failure),
  rememberFamilyFact: (input: MemoryFactInput) => ipcRenderer.invoke("rocky:remember-family-fact", input),
  startBackgroundResearch: (input: BackgroundResearchInput, sessionId?: string) =>
    ipcRenderer.invoke("rocky:start-background-research", input, sessionId),
  createSpreadsheet: (spec: SpreadsheetSpec, sessionId?: string) =>
    ipcRenderer.invoke("rocky:create-spreadsheet", spec, sessionId),
  updateActiveSpreadsheet: (spec: SpreadsheetSpec, sessionId?: string) =>
    ipcRenderer.invoke("rocky:update-active-spreadsheet", spec, sessionId),
  editCurrentSpreadsheet: (spec: SpreadsheetEditSpec, sessionId?: string) =>
    ipcRenderer.invoke("rocky:edit-current-spreadsheet", spec, sessionId),
  createHowToDoc: (spec: HowToDocSpec, sessionId?: string) =>
    ipcRenderer.invoke("rocky:create-how-to-doc", spec, sessionId),
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
  onResearchComplete: (listener: (sessionId: string, result: BackgroundResearchResult) => void) => {
    const handler = (_event: Electron.IpcRendererEvent, sessionId: string, result: BackgroundResearchResult): void => {
      listener(sessionId, result);
    };
    ipcRenderer.on("rocky:research-complete", handler);
    return () => ipcRenderer.removeListener("rocky:research-complete", handler);
  },
  onResearchError: (listener: (sessionId: string, result: { id: string; message: string }) => void) => {
    const handler = (_event: Electron.IpcRendererEvent, sessionId: string, result: { id: string; message: string }): void => {
      listener(sessionId, result);
    };
    ipcRenderer.on("rocky:research-error", handler);
    return () => ipcRenderer.removeListener("rocky:research-error", handler);
  },
};

contextBridge.exposeInMainWorld("rocky", rockyApi);
