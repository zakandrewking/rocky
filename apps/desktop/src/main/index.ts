import { createHash, randomUUID } from "node:crypto";
import { execFile } from "node:child_process";
import { existsSync } from "node:fs";
import { appendFile, mkdir, readFile, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { promisify } from "node:util";

import { config as loadEnv } from "dotenv";
import { app, BrowserWindow, ipcMain, shell, systemPreferences } from "electron";

import { createRealtimeSessionConfig } from "./realtimeSession";
import { HumeSpeech } from "./humeSpeech";
import { OnlyOfficeBridge } from "./onlyOfficeBridge";
import { formatMemoryForPrompt, readFamilyMemory, rememberFamilyFact } from "./memory";
import { normalizeSpreadsheetSpec, writeSpreadsheet } from "./spreadsheet";
import type { RockyStyleFailure } from "../shared/rockyStyle";
import type { MemoryFactInput, TranscriptEntry, TranscriptRole } from "../shared/types";

const MODEL = process.env.ROCKY_REALTIME_MODEL ?? "gpt-realtime-2.1";
const VOICE = process.env.ROCKY_VOICE ?? "cedar";
const execFileAsync = promisify(execFile);
const ONLYOFFICE_APP = "/Applications/ONLYOFFICE.app";
const humeSpeechSessions = new Map<string, { ownerId: number; speech: HumeSpeech }>();
let onlyOfficeBridge: OnlyOfficeBridge | null = null;

interface HumeSettings {
  apiKey: string;
  voiceId: string;
}

function loadEnvironment(): void {
  const candidates = [
    path.join(process.cwd(), ".env"),
    path.resolve(process.cwd(), "../../.env"),
    path.join(app.getPath("userData"), ".env"),
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

function transcriptDirectory(): string {
  return path.join(localDataDirectory(), "transcripts");
}

function memoryFilePath(): string {
  return path.join(localDataDirectory(), "memory.json");
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

async function openSpreadsheetInOnlyOffice(filePath: string): Promise<void> {
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

async function createRealtimeSession(): Promise<unknown> {
  const apiKey = process.env.OPENAI_API_KEY;
  if (!apiKey) {
    throw new Error("OPENAI_API_KEY is missing. Add it to the repository .env file and restart Rocky.");
  }

  const safetyIdentifier = createHash("sha256")
    .update(`rocky-local-family:${os.hostname()}`)
    .digest("hex");
  const memoryContext = formatMemoryForPrompt(await readFamilyMemory(memoryFilePath()));
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
  ipcMain.handle("rocky:record-style-failure", (_event, failure: RockyStyleFailure) => recordStyleFailure(failure));
  ipcMain.handle("rocky:remember-family-fact", (_event, input: MemoryFactInput) =>
    rememberFamilyFact(memoryFilePath(), input));
  ipcMain.handle("rocky:create-spreadsheet", async (_event, spec: unknown, sessionId?: string) => {
    const result = await writeSpreadsheet(spec, spreadsheetDirectory());
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
    await openSpreadsheetInOnlyOffice(filePath);
  });
  ipcMain.handle("rocky:reveal-spreadsheet", (_event, filePath: string) => {
    shell.showItemInFolder(filePath);
  });
  ipcMain.handle("rocky:hume-speak", async (event, sessionId: string, text: string) => {
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
    await active.speech.speak(text);
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
