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

export interface SpreadsheetCellEdit {
  cell: string;
  value: CellValue;
  sheet?: string;
}

export interface SpreadsheetAppendRowsEdit {
  sheet?: string;
  rows: CellValue[][];
}

export interface SpreadsheetEditSpec {
  setCells?: SpreadsheetCellEdit[];
  appendRows?: SpreadsheetAppendRowsEdit[];
}

export interface SpreadsheetEditResult {
  path: string;
  filename: string;
  setCells: SpreadsheetCellEdit[];
  appendedRows: Array<{ sheet: string; startRow: number; rows: CellValue[][] }>;
}

export interface SpreadsheetInspectSpec {
  sheet?: string;
  range?: string;
}

export interface SpreadsheetInspectResult {
  path: string;
  filename: string;
  sheets: Array<{ name: string; rowCount: number; columnCount: number }>;
  inspected?: {
    sheet: string;
    range: string;
    rows: CellValue[][];
  };
}

export interface HowToDocSection {
  heading: string;
  bullets: string[];
}

export interface HowToDocSpec {
  title: string;
  filename?: string;
  purpose?: string;
  materials?: string[];
  steps: string[];
  safetyNotes?: string[];
  tips?: string[];
  sections?: HowToDocSection[];
}

export interface HowToDocResult {
  path: string;
  filename: string;
  title: string;
  steps: string[];
}

export type RockyFileKind = "spreadsheet" | "document";

export interface RockyFileRecord {
  kind: RockyFileKind;
  filename: string;
  path: string;
  updatedAt: string;
}

export interface RockyFileListInput {
  kind?: RockyFileKind;
  limit?: number;
}

export interface RockyFileOpenInput {
  kind?: RockyFileKind;
  filename?: string;
  latest?: boolean;
}

export interface RockyFileOpenResult extends RockyFileRecord {
  opened: boolean;
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

export interface BackgroundResearchInput {
  question: string;
  context?: string;
}

export interface BackgroundResearchStarted {
  id: string;
  question: string;
  message: string;
}

export interface BackgroundResearchResult {
  id: string;
  question: string;
  answer: string;
  path: string;
  completedAt: string;
}

export interface BackgroundResearchStatus {
  id: string;
  status: "started" | "complete" | "error";
  updatedAt: string;
  question?: string;
  path?: string;
  message?: string;
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

export interface DebugLogEntry {
  event: string;
  sessionId?: string;
  phase?: string;
  detail?: Record<string, unknown>;
}

export interface OnlyOfficeBridgeStatus {
  connected: boolean;
  lastPollAt: number | null;
  msSinceLastPoll: number | null;
  queued: number;
  pending: number;
}

export interface RockyApi {
  getConfig: () => Promise<RockyConfig>;
  createRealtimeSession: () => Promise<RealtimeSessionSecret>;
  startTranscript: () => Promise<TranscriptSession>;
  appendTranscript: (entry: TranscriptEntry) => Promise<void>;
  appendDebugLog: (entry: DebugLogEntry) => Promise<void>;
  recordStyleFailure: (failure: RockyStyleFailure) => Promise<void>;
  rememberFamilyFact: (input: MemoryFactInput) => Promise<MemoryFactResult>;
  startBackgroundResearch: (
    input: BackgroundResearchInput,
    sessionId?: string,
  ) => Promise<BackgroundResearchStarted>;
  listBackgroundResearch: () => Promise<BackgroundResearchStatus[]>;
  getOnlyOfficeStatus: () => Promise<OnlyOfficeBridgeStatus>;
  createSpreadsheet: (spec: SpreadsheetSpec, sessionId?: string) => Promise<SpreadsheetResult>;
  updateActiveSpreadsheet: (spec: SpreadsheetSpec, sessionId?: string) => Promise<void>;
  inspectCurrentSpreadsheet: (spec: SpreadsheetInspectSpec, sessionId?: string) => Promise<SpreadsheetInspectResult>;
  editCurrentSpreadsheet: (spec: SpreadsheetEditSpec, sessionId?: string) => Promise<SpreadsheetEditResult>;
  createHowToDoc: (spec: HowToDocSpec, sessionId?: string) => Promise<HowToDocResult>;
  listRockyFiles: (input: RockyFileListInput, sessionId?: string) => Promise<RockyFileRecord[]>;
  openRockyFile: (input: RockyFileOpenInput, sessionId?: string) => Promise<RockyFileOpenResult>;
  openSpreadsheet: (filePath: string) => Promise<void>;
  revealSpreadsheet: (filePath: string) => Promise<void>;
  speakWithHume: (sessionId: string, text: string, flush?: boolean) => Promise<void>;
  cancelHumeSpeech: (sessionId: string) => Promise<void>;
  onHumeAudio: (listener: (sessionId: string, event: HumeAudioEvent) => void) => () => void;
  onResearchComplete: (listener: (sessionId: string, result: BackgroundResearchResult) => void) => () => void;
  onResearchError: (listener: (sessionId: string, result: { id: string; message: string }) => void) => () => void;
}
