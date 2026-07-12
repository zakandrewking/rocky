import { readFile, writeFile } from "node:fs/promises";

function readEnvValue(source, name) {
  const escaped = name.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const match = source.match(new RegExp(`^\\s*${escaped}\\s*=\\s*(.+?)\\s*$`, "m"));
  return match?.[1].replace(/^['"]|['"]$/g, "").trim() || undefined;
}

const root = new URL("../", import.meta.url);
const env = await readFile(new URL(".env", root), "utf8");
const apiKey = readEnvValue(env, "HUME_API_KEY");
if (!apiKey) throw new Error("HUME_API_KEY is missing from .env.");

const args = process.argv.slice(2).filter((argument) => argument !== "--");
const replaceExisting = args.includes("--replace");
const rawIndex = args.find((argument) => argument !== "--replace") ?? "3";
const candidateIndex = Number.parseInt(rawIndex, 10);
if (!Number.isInteger(candidateIndex) || candidateIndex < 1) {
  throw new Error("Candidate index must be a positive integer, for example: pnpm voice:hume:save -- 3");
}

const outputDirectory = new URL("local-data/voice-clone/hume/", root);
const savedVoiceUrl = new URL("saved-voice.json", outputDirectory);
try {
  const existing = JSON.parse(await readFile(savedVoiceUrl, "utf8"));
  if (existing?.id && !replaceExisting) {
    console.log("A private Hume voice is already saved locally. Delete saved-voice.json only if replacing it intentionally.");
    console.log("Or run: pnpm voice:hume:save -- <candidate> --replace");
    process.exit(0);
  }
} catch (error) {
  if (error?.code !== "ENOENT") throw error;
}

const manifest = JSON.parse(await readFile(new URL("manifest.json", outputDirectory), "utf8"));
const candidate = manifest.candidates?.[candidateIndex - 1];
if (!candidate?.generationId) throw new Error(`Candidate ${candidateIndex} has no Hume generation ID.`);
const name = readEnvValue(env, "HUME_VOICE_NAME") || "Rocky Original";

const response = await fetch("https://api.hume.ai/v0/tts/voices", {
  method: "POST",
  headers: {
    "Content-Type": "application/json",
    "X-Hume-Api-Key": apiKey,
  },
  body: JSON.stringify({ generation_id: candidate.generationId, name }),
});
if (!response.ok) throw new Error(`Hume ${response.status}: ${(await response.text()).slice(0, 800)}`);

const voice = await response.json();
await writeFile(
  savedVoiceUrl,
  `${JSON.stringify({ ...voice, candidateIndex, savedAt: new Date().toISOString() }, null, 2)}\n`,
  "utf8",
);
console.log(`Saved candidate ${candidateIndex} as private Hume voice “${voice.name ?? name}”.`);
console.log("Its private ID is recorded only in local-data/voice-clone/hume/saved-voice.json.");
