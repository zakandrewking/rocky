import { createHash, randomUUID } from "node:crypto";
import { execFile } from "node:child_process";
import { existsSync } from "node:fs";
import { appendFile, mkdir, readdir, readFile, stat, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { promisify } from "node:util";

import { config as loadEnv } from "dotenv";
import { app, BrowserWindow, ipcMain, shell, systemPreferences } from "electron";

import { createRealtimeSessionConfig } from "./realtimeSession";
import { formatRecentResearchForPrompt, normalizeResearchInput, runBackgroundResearch } from "./backgroundResearch";
import { writeHowToDoc } from "./howToDocument";
import { HumeSpeech } from "./humeSpeech";
import { columnName, OnlyOfficeBridge } from "./onlyOfficeBridge";
import { formatMemoryForPrompt, readFamilyMemory, rememberFamilyFact } from "./memory";
import { appendContinuity, formatContinuityForPrompt } from "./sessionContinuity";
import {
  editSpreadsheetFile,
  inspectSpreadsheetFile,
  latestSpreadsheetPath,
  normalizeSpreadsheetSpec,
  writeSpreadsheet,
} from "./spreadsheet";
import type { RockyStyleFailure } from "../shared/rockyStyle";
import type {
  DebugLogEntry,
  MemoryFactInput,
  RockyFileKind,
  RockyFileListInput,
  RockyFileOpenInput,
  RockyFileRecord,
  TranscriptEntry,
  TranscriptRole,
} from "../shared/types";

const MODEL = process.env.ROCKY_REALTIME_MODEL ?? "gpt-realtime-2.1";
const VOICE = process.env.ROCKY_VOICE ?? "cedar";
const execFileAsync = promisify(execFile);
const ONLYOFFICE_APP = "/Applications/ONLYOFFICE.app";
const humeSpeechSessions = new Map<string, { ownerId: number; speech: HumeSpeech }>();
let onlyOfficeBridge: OnlyOfficeBridge | null = null;
let currentSpreadsheetPath: string | null = null;

interface HumeSettings {
  apiKey: string;
  voiceId: string;
}

function loadEnvironment(): void {
  const candidates = [
    path.join(app.getPath("userData"), "config.env"),
    path.join(app.getPath("userData"), ".env"),
    path.join(process.cwd(), ".env"),
    path.resolve(process.cwd(), "../../.env"),
  ];
  for (const envPath of candidates) loadEnv({ path: envPath, override: false, quiet: true });
}

function localDataDirectory(): string {
  if (!app.isPackaged) {
    const candidates = [process.cwd(), path.resolve(process.cwd(), "../..")];
    const workspace = candidates.find((candidate) => existsSync(path.join(candidate, "pnpm-workspace.yaml")));
    if (workspace) return path.join(workspace, "local-data");
  }
  return path.join(app.getPath("userData"), "local-data");
}

function spreadsheetDirectory(): string {
  return path.join(localDataDirectory(), "spreadsheets");
}

function documentDirectory(): string {
  return path.join(localDataDirectory(), "documents");
}

function transcriptDirectory(): string {
  return path.join(localDataDirectory(), "transcripts");
}

function debugDirectory(): string {
  return path.join(localDataDirectory(), "debug");
}

function memoryFilePath(): string {
  return path.join(localDataDirectory(), "memory.json");
}

function continuityFilePath(): string {
  return path.join(localDataDirectory(), "continuity.json");
}

function researchDirectory(): string {
  return path.join(localDataDirectory(), "research");
}

function researchStatusDirectory(): string {
  return path.join(researchDirectory(), "status");
}

function rockyFileGroups(): Array<{ kind: RockyFileKind; directory: string; extension: string }> {
  return [
    { kind: "spreadsheet", directory: spreadsheetDirectory(), extension: ".xlsx" },
    { kind: "document", directory: documentDirectory(), extension: ".docx" },
  ];
}

async function writeResearchStatus(
  id: string,
  status: "started" | "complete" | "error",
  detail: Record<string, unknown>,
): Promise<void> {
  await mkdir(researchStatusDirectory(), { recursive: true });
  await writeFile(
    path.join(researchStatusDirectory(), `${id}.json`),
    `${JSON.stringify({ id, status, updatedAt: new Date().toISOString(), ...detail }, null, 2)}\n`,
    "utf8",
  );
  await appendDebugLog({
    event: `research:${status}`,
    detail: { id, ...detail },
  });
}

async function resolveCurrentSpreadsheetPath(): Promise<string> {
  if (currentSpreadsheetPath && existsSync(currentSpreadsheetPath)) return currentSpreadsheetPath;
  const latest = await latestSpreadsheetPath(spreadsheetDirectory());
  if (!latest) throw new Error("Rocky has no local spreadsheet workbook yet. Create a spreadsheet first.");
  currentSpreadsheetPath = latest;
  return latest;
}

function normalizeFileKind(value: unknown): RockyFileKind | undefined {
  if (value === "spreadsheet" || value === "document") return value;
  if (value === undefined || value === null || value === "") return undefined;
  throw new Error("File kind must be spreadsheet or document.");
}

function safeRockyFilename(value: unknown): string | undefined {
  if (typeof value !== "string") return undefined;
  const filename = value.trim();
  if (!filename) return undefined;
  if (filename.includes("/") || filename.includes("\\") || filename === "." || filename === "..") {
    throw new Error("Use a saved Rocky filename, not a path.");
  }
  return filename;
}

async function listRockyFileRecords(input: RockyFileListInput = {}): Promise<RockyFileRecord[]> {
  const kind = normalizeFileKind(input.kind);
  const limit = Math.max(1, Math.min(30, Number(input.limit) || 10));
  const groups = rockyFileGroups().filter((group) => !kind || group.kind === kind);
  const records: Array<RockyFileRecord & { mtimeMs: number }> = [];
  for (const group of groups) {
    const filenames = await readdir(group.directory).catch(() => []);
    const files = await Promise.all(
      filenames
        .filter((filename) => filename.toLowerCase().endsWith(group.extension) && !filename.startsWith("~$"))
        .map(async (filename) => {
          const filePath = path.join(group.directory, filename);
          try {
            const metadata = await stat(filePath);
            return metadata.isFile()
              ? {
                kind: group.kind,
                filename,
                path: filePath,
                updatedAt: metadata.mtime.toISOString(),
                mtimeMs: metadata.mtimeMs,
              }
              : null;
          } catch {
            return null;
          }
        }),
    );
    for (const file of files) {
      if (file) records.push(file);
    }
  }
  return records
    .sort((left, right) => right.mtimeMs - left.mtimeMs)
    .slice(0, limit)
    .map(({ kind: recordKind, filename, path: filePath, updatedAt }) => ({
      kind: recordKind,
      filename,
      path: filePath,
      updatedAt,
    }));
}

async function recentFilesForPrompt(): Promise<string> {
  const lines: string[] = [];
  for (const [kind, label] of [["spreadsheet", "spreadsheets"], ["document", "documents"]] as const) {
    const recent = await listRockyFileRecords({ kind, limit: 5 });
    if (recent.length) {
      lines.push(`${label}:`);
      for (const file of recent) lines.push(`- ${file.filename} (${file.path})`);
    }
  }
  return lines.join("\n");
}

async function openSavedRockyFile(input: RockyFileOpenInput): Promise<RockyFileRecord> {
  const kind = normalizeFileKind(input.kind);
  const filename = safeRockyFilename(input.filename);
  if (!filename && !input.latest) throw new Error("Provide a saved filename or set latest=true.");
  if (input.latest && !kind) throw new Error("Provide kind when opening the latest Rocky file.");
  const candidates = await listRockyFileRecords({ ...(kind ? { kind } : {}), limit: 30 });
  const match = filename
    ? candidates.find((file) => file.filename.toLowerCase() === filename.toLowerCase())
    : candidates[0];
  if (!match) throw new Error("No matching saved Rocky file found.");
  const resolved = path.resolve(match.path);
  const allowedGroup = rockyFileGroups().find((group) =>
    group.kind === match.kind && resolved.startsWith(`${path.resolve(group.directory)}${path.sep}`));
  if (!allowedGroup) throw new Error("Saved Rocky file is outside the allowed local-data folder.");
  await openFileInOnlyOffice(resolved);
  if (match.kind === "spreadsheet") currentSpreadsheetPath = resolved;
  return { ...match, path: resolved };
}

async function readHumeSettings(): Promise<HumeSettings | null> {
  if (process.env.ROCKY_SPEECH_PROVIDER === "openai") return null;
  const apiKey = process.env.HUME_API_KEY;
  if (!apiKey) return null;
  let voiceId = process.env.HUME_VOICE_ID;
  if (!voiceId) {
    try {
      const saved = JSON.parse(
        await readFile(path.join(localDataDirectory(), "voice-clone/hume/saved-voice.json"), "utf8"),
      ) as { id?: unknown };
      if (typeof saved.id === "string") voiceId = saved.id;
    } catch {
      return null;
    }
  }
  return voiceId ? { apiKey, voiceId } : null;
}

function transcriptPath(sessionId: string): string {
  if (!/^[a-zA-Z0-9_-]+$/.test(sessionId)) throw new Error("Invalid transcript session identifier.");
  return path.join(transcriptDirectory(), `${sessionId}.md`);
}

async function startTranscript(): Promise<{ sessionId: string; path: string }> {
  const date = new Date();
  const timestamp = date.toISOString().replace(/[:.]/g, "-");
  const sessionId = `${timestamp}-${randomUUID().slice(0, 8)}`;
  const filePath = transcriptPath(sessionId);
  await mkdir(transcriptDirectory(), { recursive: true });
  await writeFile(
    filePath,
    `# Rocky conversation\n\nStarted: ${date.toLocaleString()}\n\n`,
    "utf8",
  );
  return { sessionId, path: filePath };
}

async function appendTranscript(entry: TranscriptEntry): Promise<void> {
  const labels: Record<TranscriptRole, string> = {
    user: "You",
    rocky: "Rocky",
    tool: "Rocky tool",
    system: "System",
  };
  if (!(entry.role in labels)) throw new Error("Invalid transcript role.");
  const text = entry.text.trim().replace(/\s*\n\s*/g, " ").slice(0, 10_000);
  if (!text) return;
  const time = new Date().toLocaleTimeString();
  await appendFile(transcriptPath(entry.sessionId), `**${labels[entry.role]} · ${time}**  \n${text}\n\n`, "utf8");
  await appendContinuity(continuityFilePath(), { ...entry, text });
}

async function appendDebugLog(entry: DebugLogEntry): Promise<void> {
  const safeEntry = {
    at: new Date().toISOString(),
    event: String(entry.event).slice(0, 120),
    sessionId: entry.sessionId?.slice(0, 80),
    phase: entry.phase?.slice(0, 40),
    detail: entry.detail ?? {},
  };
  await mkdir(debugDirectory(), { recursive: true });
  await appendFile(path.join(debugDirectory(), "rocky-state.jsonl"), `${JSON.stringify(safeEntry)}\n`, "utf8");
}

async function recordStyleFailure(failure: RockyStyleFailure): Promise<void> {
  const directory = path.join(localDataDirectory(), "evals");
  await mkdir(directory, { recursive: true });
  const safeText = failure.text.trim().replace(/\s*\n\s*/g, " ").slice(0, 10_000);
  const failedRules = failure.failures.map((item) => `  - ${item}`).join("\n");
  await appendFile(
    path.join(directory, "realtime-failures.md"),
    `## ${new Date().toLocaleString()} · ${failure.caseName}\n\n${safeText}\n\n${failedRules}\n\n`,
    "utf8",
  );
}

async function openFileInOnlyOffice(filePath: string): Promise<void> {
  if (process.platform === "darwin") {
    if (!existsSync(ONLYOFFICE_APP)) {
      throw new Error("ONLYOFFICE is not installed in /Applications. Run: brew install --cask onlyoffice");
    }
    await execFileAsync("/usr/bin/open", ["-a", ONLYOFFICE_APP, filePath]);
    await new Promise((resolve) => setTimeout(resolve, 900));
    await execFileAsync("/usr/bin/osascript", [
      "-e",
      'tell application "ONLYOFFICE" to activate',
    ]);
    return;
  }

  const openError = await shell.openPath(filePath);
  if (openError) throw new Error(openError);
}

async function openSpreadsheetInOnlyOffice(filePath: string): Promise<void> {
  await openFileInOnlyOffice(filePath);
}

async function openDocumentInOnlyOffice(filePath: string): Promise<void> {
  await openFileInOnlyOffice(filePath);
}

async function createRealtimeSession(): Promise<unknown> {
  const apiKey = process.env.OPENAI_API_KEY;
  if (!apiKey) {
    throw new Error(
      `OPENAI_API_KEY is missing. Add it to ${path.join(app.getPath("userData"), "config.env")} and restart Rocky.`,
    );
  }

  const safetyIdentifier = createHash("sha256")
    .update(`rocky-local-family:${os.hostname()}`)
    .digest("hex");
  const memoryContext = formatMemoryForPrompt(await readFamilyMemory(memoryFilePath()));
  const continuityContext = await formatContinuityForPrompt(continuityFilePath());
  const researchContext = await formatRecentResearchForPrompt(researchDirectory());
  const localFileContext = await recentFilesForPrompt();
  const hume = await readHumeSettings();
  const response = await fetch("https://api.openai.com/v1/realtime/client_secrets", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${apiKey}`,
      "Content-Type": "application/json",
      "OpenAI-Safety-Identifier": safetyIdentifier,
    },
    body: JSON.stringify({
      session: createRealtimeSessionConfig(
        process.env.ROCKY_REALTIME_MODEL ?? MODEL,
        process.env.ROCKY_VOICE ?? VOICE,
        memoryContext,
        continuityContext,
        { researchContext, localFileContext },
        hume ? "text" : "audio",
      ),
    }),
  });

  if (!response.ok) {
    const details = (await response.text()).slice(0, 800);
    throw new Error(`OpenAI session creation failed (${response.status}): ${details}`);
  }
  return response.json();
}

function registerIpc(): void {
  ipcMain.handle("rocky:get-config", async () => ({
    hasApiKey: Boolean(process.env.OPENAI_API_KEY),
    model: process.env.ROCKY_REALTIME_MODEL ?? MODEL,
    voice: process.env.ROCKY_VOICE ?? VOICE,
    spreadsheetDirectory: spreadsheetDirectory(),
    spreadsheetApplication: process.platform === "darwin" ? "ONLYOFFICE" : "System default",
    localDataDirectory: localDataDirectory(),
    alienVoiceEnabled: process.env.ROCKY_ALIEN_VOICE !== "0",
    alienVoiceVolume: Math.max(0, Math.min(0.18, Number(process.env.ROCKY_ALIEN_VOICE_VOLUME) || 0.045)),
    alienVoiceTimeScale: Math.max(0.45, Math.min(1, Number(process.env.ROCKY_ALIEN_VOICE_TIME_SCALE) || 0.68)),
    humeExtraDelayMs: Math.max(0, Math.min(1_000, Number(process.env.ROCKY_HUME_EXTRA_DELAY_MS) || 0)),
    speechProvider: await readHumeSettings() ? "hume" : "openai",
  }));
  ipcMain.handle("rocky:create-realtime-session", createRealtimeSession);
  ipcMain.handle("rocky:start-transcript", startTranscript);
  ipcMain.handle("rocky:append-transcript", (_event, entry: TranscriptEntry) => appendTranscript(entry));
  ipcMain.handle("rocky:append-debug-log", (_event, entry: DebugLogEntry) => appendDebugLog(entry));
  ipcMain.handle("rocky:record-style-failure", (_event, failure: RockyStyleFailure) => recordStyleFailure(failure));
  ipcMain.handle("rocky:remember-family-fact", (_event, input: MemoryFactInput) =>
    rememberFamilyFact(memoryFilePath(), input));
  ipcMain.handle("rocky:start-background-research", async (event, input: unknown, sessionId?: string) => {
    const apiKey = process.env.OPENAI_API_KEY;
    if (!apiKey) throw new Error("OPENAI_API_KEY is missing.");
    const normalized = normalizeResearchInput(input);
    const id = randomUUID();
    if (sessionId) {
      await appendTranscript({ sessionId, role: "tool", text: `Started background research: ${normalized.question}` });
    }
    await writeResearchStatus(id, "started", {
      question: normalized.question,
      sessionId: sessionId ?? "",
    });
    const sender = event.sender;
    void runBackgroundResearch(normalized, researchDirectory(), apiKey, id)
      .then(async (result) => {
        await writeResearchStatus(id, "complete", {
          question: result.question,
          path: result.path,
        }).catch(() => undefined);
        if (sessionId) {
          await appendTranscript({
            sessionId,
            role: "tool",
            text: `Background research complete: ${result.question} ${result.answer}`,
          }).catch(() => undefined);
        }
        if (!sender.isDestroyed()) sender.send("rocky:research-complete", sessionId ?? "", result);
      })
      .catch(async (error) => {
        const message = error instanceof Error && error.name === "AbortError"
          ? "Background research timed out before OpenAI returned a result."
          : error instanceof Error ? error.message : String(error);
        await writeResearchStatus(id, "error", {
          question: normalized.question,
          message,
        }).catch(() => undefined);
        if (sessionId) {
          await appendTranscript({ sessionId, role: "system", text: `Background research failed: ${message}` })
            .catch(() => undefined);
        }
        if (!sender.isDestroyed()) sender.send("rocky:research-error", sessionId ?? "", { id, message });
      });
    return { id, question: normalized.question, message: "Background research started." };
  });
  ipcMain.handle("rocky:create-spreadsheet", async (_event, spec: unknown, sessionId?: string) => {
    const result = await writeSpreadsheet(spec, spreadsheetDirectory());
    currentSpreadsheetPath = result.path;
    await openSpreadsheetInOnlyOffice(result.path);
    if (sessionId) {
      await appendTranscript({
        sessionId,
        role: "tool",
        text: `Created and opened spreadsheet: ${result.filename}`,
      });
    }
    return result;
  });
  ipcMain.handle("rocky:inspect-current-spreadsheet", async (_event, spec: unknown, sessionId?: string) => {
    const filePath = await resolveCurrentSpreadsheetPath();
    const result = await inspectSpreadsheetFile(filePath, spec);
    if (sessionId) {
      await appendTranscript({
        sessionId,
        role: "tool",
        text: `Inspected current spreadsheet: ${result.filename} ${result.inspected?.sheet ?? ""} ${result.inspected?.range ?? ""}`,
      });
    }
    return result;
  });
  ipcMain.handle("rocky:edit-current-spreadsheet", async (_event, spec: unknown, sessionId?: string) => {
    const filePath = await resolveCurrentSpreadsheetPath();
    const result = await editSpreadsheetFile(filePath, spec);
    const cells = result.setCells.map((edit) => ({ address: edit.cell, value: edit.value }));
    const ranges = result.appendedRows.map((edit) => ({
      targetRange: `A${edit.startRow}:${columnName(Math.max(...edit.rows.map((row) => row.length), 1) - 1)}${edit.startRow + edit.rows.length - 1}`,
      values: edit.rows,
    }));
    if (onlyOfficeBridge?.isConnected()) {
      await onlyOfficeBridge.editActiveSheet(cells, ranges);
    } else {
      await openSpreadsheetInOnlyOffice(result.path);
    }
    if (sessionId) {
      await appendTranscript({
        sessionId,
        role: "tool",
        text: `Edited current spreadsheet: ${result.filename}`,
      });
    }
    return result;
  });
  ipcMain.handle("rocky:create-how-to-doc", async (_event, spec: unknown, sessionId?: string) => {
    const result = await writeHowToDoc(spec, documentDirectory());
    await openDocumentInOnlyOffice(result.path);
    if (sessionId) {
      await appendTranscript({
        sessionId,
        role: "tool",
        text: `Created and opened how-to document: ${result.filename}`,
      });
    }
    return result;
  });
  ipcMain.handle("rocky:list-rocky-files", async (_event, input: RockyFileListInput = {}, sessionId?: string) => {
    const result = await listRockyFileRecords(input);
    if (sessionId) {
      await appendTranscript({
        sessionId,
        role: "tool",
        text: `Listed saved Rocky files: ${result.map((file) => file.filename).join(", ") || "none"}`,
      });
    }
    return result;
  });
  ipcMain.handle("rocky:open-rocky-file", async (_event, input: RockyFileOpenInput, sessionId?: string) => {
    const result = await openSavedRockyFile(input);
    if (sessionId) {
      await appendTranscript({
        sessionId,
        role: "tool",
        text: `Opened saved Rocky file: ${result.filename}`,
      });
    }
    return { ...result, opened: true };
  });
  ipcMain.handle("rocky:update-active-spreadsheet", async (_event, spec: unknown, sessionId?: string) => {
    if (!onlyOfficeBridge) throw new Error("ONLYOFFICE live-update bridge is not running.");
    const normalized = normalizeSpreadsheetSpec(spec);
    await onlyOfficeBridge.replaceActiveSheet(normalized);
    if (sessionId) {
      await appendTranscript({
        sessionId,
        role: "tool",
        text: `Updated visible active spreadsheet in place: ${normalized.sheets[0]?.name ?? normalized.title}`,
      });
    }
  });
  ipcMain.handle("rocky:open-spreadsheet", async (_event, filePath: string) => {
    currentSpreadsheetPath = filePath;
    await openSpreadsheetInOnlyOffice(filePath);
  });
  ipcMain.handle("rocky:reveal-spreadsheet", (_event, filePath: string) => {
    shell.showItemInFolder(filePath);
  });
  ipcMain.handle("rocky:hume-speak", async (event, sessionId: string, text: string, flush = true) => {
    transcriptPath(sessionId);
    const settings = await readHumeSettings();
    if (!settings) throw new Error("Hume speech is not configured.");
    let active = humeSpeechSessions.get(sessionId);
    if (active && active.ownerId !== event.sender.id) throw new Error("Invalid Hume speech session owner.");
    if (!active) {
      const sender = event.sender;
      const speech = new HumeSpeech(settings.apiKey, settings.voiceId, (audioEvent) => {
        if (!sender.isDestroyed()) sender.send("rocky:hume-audio", sessionId, audioEvent);
      });
      active = { ownerId: sender.id, speech };
      humeSpeechSessions.set(sessionId, active);
    }
    await active.speech.speak(text, flush);
  });
  ipcMain.handle("rocky:hume-cancel", (event, sessionId: string) => {
    transcriptPath(sessionId);
    const active = humeSpeechSessions.get(sessionId);
    if (!active || active.ownerId !== event.sender.id) return;
    active.speech.cancel();
    humeSpeechSessions.delete(sessionId);
  });
}

function createWindow(): void {
  const window = new BrowserWindow({
    width: 720,
    height: 760,
    minWidth: 520,
    minHeight: 600,
    backgroundColor: "#080b0a",
    titleBarStyle: "hiddenInset",
    trafficLightPosition: { x: 18, y: 18 },
    webPreferences: {
      preload: path.join(__dirname, "../preload/index.js"),
      contextIsolation: true,
      nodeIntegration: false,
    },
  });

  if (process.platform === "darwin") {
    systemPreferences.askForMediaAccess("microphone").catch(() => undefined);
  }

  if (process.env.ELECTRON_RENDERER_URL) {
    void window.loadURL(process.env.ELECTRON_RENDERER_URL);
  } else {
    void window.loadFile(path.join(__dirname, "../renderer/index.html"));
  }
}

app.whenReady().then(async () => {
  loadEnvironment();
  onlyOfficeBridge = new OnlyOfficeBridge(path.join(localDataDirectory(), "onlyoffice-bridge.json"));
  await onlyOfficeBridge.start().catch(() => {
    onlyOfficeBridge = null;
  });
  registerIpc();
  createWindow();
  app.on("activate", () => {
    if (BrowserWindow.getAllWindows().length === 0) createWindow();
  });
});

app.on("window-all-closed", () => {
  if (process.platform !== "darwin") app.quit();
});

app.on("before-quit", () => onlyOfficeBridge?.stop());
