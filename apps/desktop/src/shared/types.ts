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
  alienVoiceEnabled: boolean;
  alienVoiceVolume: number;
  alienVoiceTimeScale: number;
  humeExtraDelayMs: number;
  speechProvider: "openai" | "hume";
}

export type HumeAudioEvent =
  | { type: "audio"; audio: string; sampleRate: number; isLastChunk: boolean }
  | { type: "error"; message: string };

export interface MemoryFact {
  text: string;
  createdAt: string;
}

export interface PersonMemory {
  name: string;
  facts: MemoryFact[];
}

export interface FamilyMemory {
  version: 1;
  updatedAt: string;
  people: PersonMemory[];
}

export interface MemoryFactInput {
  person: string;
  fact: string;
}

export interface MemoryFactResult extends MemoryFactInput {
  saved: boolean;
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
  rememberFamilyFact: (input: MemoryFactInput) => Promise<MemoryFactResult>;
  createSpreadsheet: (spec: SpreadsheetSpec, sessionId?: string) => Promise<SpreadsheetResult>;
  updateActiveSpreadsheet: (spec: SpreadsheetSpec, sessionId?: string) => Promise<void>;
  openSpreadsheet: (filePath: string) => Promise<void>;
  revealSpreadsheet: (filePath: string) => Promise<void>;
  speakWithHume: (sessionId: string, text: string, flush?: boolean) => Promise<void>;
  cancelHumeSpeech: (sessionId: string) => Promise<void>;
  onHumeAudio: (listener: (sessionId: string, event: HumeAudioEvent) => void) => () => void;
}
