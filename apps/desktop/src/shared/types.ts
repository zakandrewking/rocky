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
}

export interface RockyApi {
  getConfig: () => Promise<RockyConfig>;
  createRealtimeSession: () => Promise<RealtimeSessionSecret>;
  createSpreadsheet: (spec: SpreadsheetSpec) => Promise<SpreadsheetResult>;
  openSpreadsheet: (filePath: string) => Promise<void>;
  revealSpreadsheet: (filePath: string) => Promise<void>;
}

