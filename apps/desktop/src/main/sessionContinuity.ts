import { mkdir, readFile, writeFile } from "node:fs/promises";
import path from "node:path";

import type { TranscriptEntry, TranscriptRole } from "../shared/types";

const MAX_ITEMS = 24;
const MAX_TEXT_LENGTH = 900;

interface ContinuityItem {
  role: TranscriptRole;
  text: string;
  at: string;
}

interface ContinuityFile {
  version: 1;
  updatedAt: string;
  items: ContinuityItem[];
}

const ROLE_LABELS: Record<TranscriptRole, string> = {
  user: "Human",
  rocky: "Rocky",
  tool: "Tool",
  system: "System",
};

function cleanText(text: string): string {
  return text.trim().replace(/\s+/g, " ").slice(0, MAX_TEXT_LENGTH);
}

async function readContinuity(filePath: string): Promise<ContinuityFile> {
  try {
    const parsed = JSON.parse(await readFile(filePath, "utf8")) as Partial<ContinuityFile>;
    if (parsed.version === 1 && Array.isArray(parsed.items)) {
      return {
        version: 1,
        updatedAt: typeof parsed.updatedAt === "string" ? parsed.updatedAt : new Date().toISOString(),
        items: parsed.items.filter((item): item is ContinuityItem =>
          typeof item === "object"
          && item !== null
          && typeof item.text === "string"
          && typeof item.at === "string"
          && ["user", "rocky", "tool", "system"].includes(String(item.role)),
        ),
      };
    }
  } catch {
    // Start a new continuity file below.
  }
  return { version: 1, updatedAt: new Date().toISOString(), items: [] };
}

export async function appendContinuity(filePath: string, entry: TranscriptEntry): Promise<void> {
  if (entry.role === "system") return;
  const text = cleanText(entry.text);
  if (!text) return;
  const file = await readContinuity(filePath);
  file.items.push({ role: entry.role, text, at: new Date().toISOString() });
  file.items = file.items.slice(-MAX_ITEMS);
  file.updatedAt = new Date().toISOString();
  await mkdir(path.dirname(filePath), { recursive: true });
  await writeFile(filePath, `${JSON.stringify(file, null, 2)}\n`, "utf8");
}

export async function formatContinuityForPrompt(filePath: string): Promise<string> {
  const file = await readContinuity(filePath);
  const items = file.items.slice(-MAX_ITEMS);
  if (!items.length) return "";
  return items.map((item) => `${ROLE_LABELS[item.role]}: ${item.text}`).join("\n");
}
