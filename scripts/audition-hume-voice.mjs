import { mkdir, readFile, writeFile } from "node:fs/promises";

function readEnvValue(source, name) {
  const escaped = name.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const match = source.match(new RegExp(`^\\s*${escaped}\\s*=\\s*(.+?)\\s*$`, "m"));
  return match?.[1].replace(/^['"]|['"]$/g, "").trim() || undefined;
}

const root = new URL("../", import.meta.url);
const env = await readFile(new URL(".env", root), "utf8");
const apiKey = readEnvValue(env, "HUME_API_KEY");
if (!apiKey) throw new Error("HUME_API_KEY is missing from .env. Create a Hume key, add it locally, and retry.");

const text = process.argv.slice(2).filter((argument) => argument !== "--").join(" ").trim()
  || "Amaze. Amaze. Amaze. The ship is safe. Fist my bump.";
const description = readEnvValue(env, "HUME_VOICE_DESCRIPTION")
  || [
    "Original adult male alien observer with neutral North American vowels and no British, RP, posh, or theatrical accent.",
    "Flat, dry, precise, faintly amused, and quietly certain; more clinical visitor than audiobook narrator.",
    "Avoid polished narrator warmth, rounded UK vowels, stage diction, fantasy creature acting, and grand resonance.",
    "Short clipped phrases. Low emotional volume. Curiosity leaks through as tiny surprise, not bouncy enthusiasm.",
    "Speak as if calmly evaluating evidence beside one trusted friend.",
  ].join(" ");

const response = await fetch("https://api.hume.ai/v0/tts", {
  method: "POST",
  headers: {
    "Content-Type": "application/json",
    "X-Hume-Api-Key": apiKey,
  },
  body: JSON.stringify({
    version: "1",
    num_generations: 3,
    utterances: [{ text, description }],
  }),
});
if (!response.ok) throw new Error(`Hume ${response.status}: ${(await response.text()).slice(0, 800)}`);

const payload = await response.json();
const generations = Array.isArray(payload.generations) ? payload.generations : [];
if (!generations.length) throw new Error("Hume returned no voice candidates.");

const outputDirectory = new URL("local-data/voice-clone/hume/", root);
await mkdir(outputDirectory, { recursive: true });
const candidates = [];
for (const [index, generation] of generations.entries()) {
  if (typeof generation.audio !== "string") continue;
  const filename = `candidate-${index + 1}.mp3`;
  await writeFile(new URL(filename, outputDirectory), Buffer.from(generation.audio, "base64"));
  const snippets = Array.isArray(generation.snippets) ? generation.snippets.flat() : [];
  candidates.push({
    filename,
    generationId: generation.generation_id ?? snippets[0]?.generation_id ?? null,
  });
}
if (!candidates.length) throw new Error("Hume candidates did not contain playable audio.");

await writeFile(
  new URL("manifest.json", outputDirectory),
  `${JSON.stringify({ createdAt: new Date().toISOString(), text, description, candidates }, null, 2)}\n`,
  "utf8",
);
console.log(`Saved ${candidates.length} ignored Hume candidates under local-data/voice-clone/hume/`);
console.log("Listen to candidate-1.mp3 through candidate-3.mp3, then save the winning generation in Hume.");
