import { contextBridge, ipcRenderer } from "electron";

import type { RockyApi, SpreadsheetSpec } from "../shared/types";

const rockyApi: RockyApi = {
  getConfig: () => ipcRenderer.invoke("rocky:get-config"),
  createRealtimeSession: () => ipcRenderer.invoke("rocky:create-realtime-session"),
  createSpreadsheet: (spec: SpreadsheetSpec) => ipcRenderer.invoke("rocky:create-spreadsheet", spec),
  openSpreadsheet: (filePath: string) => ipcRenderer.invoke("rocky:open-spreadsheet", filePath),
  revealSpreadsheet: (filePath: string) => ipcRenderer.invoke("rocky:reveal-spreadsheet", filePath),
};

contextBridge.exposeInMainWorld("rocky", rockyApi);

