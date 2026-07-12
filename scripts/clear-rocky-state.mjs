import { existsSync } from "node:fs";
import { rm } from "node:fs/promises";
import path from "node:path";

const root = path.resolve(new URL("..", import.meta.url).pathname);
const localData = path.join(root, "local-data");

const targets = [
  "memory.json",
  "continuity.json",
  "transcripts",
  "debug",
  "research",
  "evals",
  "onlyoffice-bridge.json",
];

for (const target of targets) {
  const fullPath = path.join(localData, target);
  if (!existsSync(fullPath)) continue;
  await rm(fullPath, { recursive: true, force: true });
  console.log(`cleared ${path.relative(root, fullPath)}`);
}

console.log("Rocky local memory/state cleared. Generated spreadsheets, documents, voice assets, and .env were kept.");
