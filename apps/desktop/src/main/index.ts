import { createHash } from "node:crypto";
import os from "node:os";
import path from "node:path";

import { config as loadEnv } from "dotenv";
import { app, BrowserWindow, ipcMain, shell, systemPreferences } from "electron";

import { ROCKY_INSTRUCTIONS, SPREADSHEET_TOOL } from "./prompt";
import { writeSpreadsheet } from "./spreadsheet";

const MODEL = process.env.ROCKY_REALTIME_MODEL ?? "gpt-realtime-2.1";
const VOICE = process.env.ROCKY_VOICE ?? "cedar";

function loadEnvironment(): void {
  const candidates = [
    path.join(process.cwd(), ".env"),
    path.resolve(process.cwd(), "../../.env"),
    path.join(app.getPath("userData"), ".env"),
  ];
  for (const envPath of candidates) loadEnv({ path: envPath, override: false, quiet: true });
}

function spreadsheetDirectory(): string {
  return path.join(app.getPath("documents"), "Rocky Spreadsheets");
}

async function createRealtimeSession(): Promise<unknown> {
  const apiKey = process.env.OPENAI_API_KEY;
  if (!apiKey) {
    throw new Error("OPENAI_API_KEY is missing. Add it to the repository .env file and restart Rocky.");
  }

  const safetyIdentifier = createHash("sha256")
    .update(`rocky-local-family:${os.hostname()}`)
    .digest("hex");
  const response = await fetch("https://api.openai.com/v1/realtime/client_secrets", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${apiKey}`,
      "Content-Type": "application/json",
      "OpenAI-Safety-Identifier": safetyIdentifier,
    },
    body: JSON.stringify({
      session: {
        type: "realtime",
        model: process.env.ROCKY_REALTIME_MODEL ?? MODEL,
        instructions: ROCKY_INSTRUCTIONS,
        audio: {
          input: {
            transcription: { model: "gpt-realtime-whisper" },
            turn_detection: {
              type: "semantic_vad",
              eagerness: "low",
              create_response: true,
              interrupt_response: true,
            },
          },
          output: { voice: process.env.ROCKY_VOICE ?? VOICE },
        },
        tools: [SPREADSHEET_TOOL],
        tool_choice: "auto",
      },
    }),
  });

  if (!response.ok) {
    const details = (await response.text()).slice(0, 800);
    throw new Error(`OpenAI session creation failed (${response.status}): ${details}`);
  }
  return response.json();
}

function registerIpc(): void {
  ipcMain.handle("rocky:get-config", () => ({
    hasApiKey: Boolean(process.env.OPENAI_API_KEY),
    model: process.env.ROCKY_REALTIME_MODEL ?? MODEL,
    voice: process.env.ROCKY_VOICE ?? VOICE,
    spreadsheetDirectory: spreadsheetDirectory(),
  }));
  ipcMain.handle("rocky:create-realtime-session", createRealtimeSession);
  ipcMain.handle("rocky:create-spreadsheet", async (_event, spec: unknown) => {
    const result = await writeSpreadsheet(spec, spreadsheetDirectory());
    const openError = await shell.openPath(result.path);
    if (openError) throw new Error(`Spreadsheet created, but macOS could not open it: ${openError}`);
    return result;
  });
  ipcMain.handle("rocky:open-spreadsheet", async (_event, filePath: string) => {
    const openError = await shell.openPath(filePath);
    if (openError) throw new Error(openError);
  });
  ipcMain.handle("rocky:reveal-spreadsheet", (_event, filePath: string) => {
    shell.showItemInFolder(filePath);
  });
}

function createWindow(): void {
  const window = new BrowserWindow({
    width: 720,
    height: 760,
    minWidth: 520,
    minHeight: 600,
    backgroundColor: "#071c25",
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

app.whenReady().then(() => {
  loadEnvironment();
  registerIpc();
  createWindow();
  app.on("activate", () => {
    if (BrowserWindow.getAllWindows().length === 0) createWindow();
  });
});

app.on("window-all-closed", () => {
  if (process.platform !== "darwin") app.quit();
});
