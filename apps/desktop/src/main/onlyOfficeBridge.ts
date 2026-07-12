import { randomBytes, randomUUID } from "node:crypto";
import { createServer, type Server } from "node:http";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import path from "node:path";

import { normalizeSpreadsheetSpec } from "./spreadsheet";
import type { CellValue, OnlyOfficeBridgeStatus, SpreadsheetSpec } from "../shared/types";

export const ONLYOFFICE_BRIDGE_PORT = 17_421;

export interface OnlyOfficeCommand {
  id: string;
  type: "replace_active_sheet" | "edit_active_sheet" | "save_active_document";
  sheetName?: string;
  values?: CellValue[][];
  targetRange?: string;
  clearRange?: string;
  cells?: Array<{ address: string; value: CellValue }>;
  ranges?: Array<{ targetRange: string; values: CellValue[][] }>;
}

interface PendingCommand {
  command: OnlyOfficeCommand;
  resolve: () => void;
  reject: (error: Error) => void;
  timeout: NodeJS.Timeout;
}

export function columnName(index: number): string {
  let value = index + 1;
  let name = "";
  while (value > 0) {
    value -= 1;
    name = String.fromCharCode(65 + (value % 26)) + name;
    value = Math.floor(value / 26);
  }
  return name;
}

export function activeSheetCommand(value: unknown): OnlyOfficeCommand {
  const spec = normalizeSpreadsheetSpec(value);
  const sheet = spec.sheets[0];
  if (!sheet) throw new Error("Spreadsheet update has no sheet.");
  const values = [sheet.columns, ...sheet.rows];
  const finalColumn = columnName(sheet.columns.length - 1);
  return {
    id: randomUUID(),
    type: "replace_active_sheet",
    sheetName: sheet.name,
    values,
    targetRange: `A1:${finalColumn}${values.length}`,
    clearRange: "A1:T201",
  };
}

export class OnlyOfficeBridge {
  private server: Server | null = null;
  private token = "";
  private lastPollAt = 0;
  private readonly queue: OnlyOfficeCommand[] = [];
  private readonly pending = new Map<string, PendingCommand>();

  constructor(private readonly tokenFile: string) {}

  async start(): Promise<void> {
    this.token = await this.readOrCreateToken();
    this.server = createServer((request, response) => {
      response.setHeader("Access-Control-Allow-Origin", "*");
      response.setHeader("Access-Control-Allow-Methods", "GET, POST, OPTIONS");
      response.setHeader("Access-Control-Allow-Headers", "Content-Type, Authorization, X-Requested-With");
      response.setHeader("Access-Control-Allow-Private-Network", "true");
      response.setHeader("Access-Control-Max-Age", "600");
      if (request.method === "OPTIONS") {
        response.writeHead(204).end();
        return;
      }
      const url = new URL(request.url ?? "/", `http://127.0.0.1:${ONLYOFFICE_BRIDGE_PORT}`);
      if (url.searchParams.get("token") !== this.token) {
        response.writeHead(403).end();
        return;
      }
      if (request.method === "GET" && url.pathname === "/next") {
        this.lastPollAt = Date.now();
        const command = this.queue.shift();
        if (!command) {
          response.writeHead(204).end();
          return;
        }
        response.setHeader("Content-Type", "application/json");
        response.end(JSON.stringify(command));
        return;
      }
      if (request.method === "GET" && url.pathname === "/status") {
        response.setHeader("Content-Type", "application/json");
        response.end(JSON.stringify(this.status()));
        return;
      }
      if (request.method === "POST" && url.pathname === "/complete") {
        const id = url.searchParams.get("id") ?? "";
        const item = this.pending.get(id);
        if (item) {
          clearTimeout(item.timeout);
          this.pending.delete(id);
          item.resolve();
        }
        response.writeHead(204).end();
        return;
      }
      response.writeHead(404).end();
    });
    await new Promise<void>((resolve, reject) => {
      this.server?.once("error", reject);
      this.server?.listen(ONLYOFFICE_BRIDGE_PORT, "127.0.0.1", resolve);
    });
  }

  isConnected(): boolean {
    return Date.now() - this.lastPollAt < 2_000;
  }

  status(): OnlyOfficeBridgeStatus {
    return {
      connected: this.isConnected(),
      lastPollAt: this.lastPollAt || null,
      msSinceLastPoll: this.lastPollAt ? Date.now() - this.lastPollAt : null,
      queued: this.queue.length,
      pending: this.pending.size,
    };
  }

  replaceActiveSheet(spec: SpreadsheetSpec): Promise<void> {
    if (!this.isConnected()) return Promise.reject(new Error("ONLYOFFICE Rocky plugin is not connected."));
    const command = activeSheetCommand(spec);
    this.queue.push(command);
    return new Promise<void>((resolve, reject) => {
      const timeout = setTimeout(() => {
        this.pending.delete(command.id);
        reject(new Error("ONLYOFFICE did not confirm the visible update."));
      }, 8_000);
      this.pending.set(command.id, { command, resolve, reject, timeout });
    });
  }

  saveActiveDocument(): Promise<void> {
    if (!this.isConnected()) return Promise.reject(new Error("ONLYOFFICE Rocky plugin is not connected."));
    const command: OnlyOfficeCommand = {
      id: randomUUID(),
      type: "save_active_document",
    };
    this.queue.push(command);
    return new Promise<void>((resolve, reject) => {
      const timeout = setTimeout(() => {
        this.pending.delete(command.id);
        reject(new Error("ONLYOFFICE did not confirm the active document save request."));
      }, 10_000);
      this.pending.set(command.id, { command, resolve, reject, timeout });
    });
  }

  editActiveSheet(
    cells: Array<{ address: string; value: CellValue }>,
    ranges: Array<{ targetRange: string; values: CellValue[][] }>,
  ): Promise<void> {
    if (!this.isConnected()) return Promise.reject(new Error("ONLYOFFICE Rocky plugin is not connected."));
    const command: OnlyOfficeCommand = {
      id: randomUUID(),
      type: "edit_active_sheet",
      cells,
      ranges,
    };
    this.queue.push(command);
    return new Promise<void>((resolve, reject) => {
      const timeout = setTimeout(() => {
        this.pending.delete(command.id);
        reject(new Error("ONLYOFFICE did not confirm the visible edit."));
      }, 8_000);
      this.pending.set(command.id, { command, resolve, reject, timeout });
    });
  }

  stop(): void {
    for (const item of this.pending.values()) {
      clearTimeout(item.timeout);
      item.reject(new Error("ONLYOFFICE bridge stopped."));
    }
    this.pending.clear();
    this.server?.close();
    this.server = null;
  }

  private async readOrCreateToken(): Promise<string> {
    try {
      const saved = JSON.parse(await readFile(this.tokenFile, "utf8")) as { token?: unknown };
      if (typeof saved.token === "string" && saved.token.length >= 32) return saved.token;
    } catch {
      // Create a fresh local token below.
    }
    const token = randomBytes(32).toString("hex");
    await mkdir(path.dirname(this.tokenFile), { recursive: true });
    await writeFile(this.tokenFile, `${JSON.stringify({ token, port: ONLYOFFICE_BRIDGE_PORT }, null, 2)}\n`, "utf8");
    return token;
  }
}
