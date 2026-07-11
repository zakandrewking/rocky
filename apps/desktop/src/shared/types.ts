import type { RockyStyleFailure } from "./rockyStyle";

export type CellValue = string | number | boolean | null;

export interface SpreadsheetSheet {
  name: string;
  columns: string[];
  rows: CellValue[][];
}

export interface SpreadsheetSpec {
  title: string;
  filename?: string;
  sheets: SpreadsheetSheet[];
}

export interface SpreadsheetResult {
  path: string;
  filename: string;
  title: string;
  sheets: SpreadsheetSheet[];
}

export interface RealtimeSessionSecret {
  value: string;
  expires_at?: number;
}

export interface RockyConfig {
  hasApiKey: boolean;
  model: string;
  voice: string;
  spreadsheetDirectory: string;
  spreadsheetApplication: string;
  localDataDirectory: string;
}

export type TranscriptRole = "user" | "rocky" | "tool" | "system";

export interface TranscriptEntry {
  sessionId: string;
  role: TranscriptRole;
  text: string;
}

export interface TranscriptSession {
  sessionId: string;
  path: string;
}

export interface RockyApi {
  getConfig: () => Promise<RockyConfig>;
  createRealtimeSession: () => Promise<RealtimeSessionSecret>;
  startTranscript: () => Promise<TranscriptSession>;
  appendTranscript: (entry: TranscriptEntry) => Promise<void>;
  recordStyleFailure: (failure: RockyStyleFailure) => Promise<void>;
  createSpreadsheet: (spec: SpreadsheetSpec, sessionId?: string) => Promise<SpreadsheetResult>;
  openSpreadsheet: (filePath: string) => Promise<void>;
  revealSpreadsheet: (filePath: string) => Promise<void>;
}
