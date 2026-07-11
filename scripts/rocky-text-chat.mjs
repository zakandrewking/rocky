import { mkdir, readFile, writeFile } from "node:fs/promises";
import process from "node:process";
import { createInterface } from "node:readline/promises";

import { formatMemoryForPrompt, readFamilyMemory } from "../apps/desktop/src/main/memory.ts";
import { ROCKY_INSTRUCTIONS } from "../apps/desktop/src/main/prompt.ts";

function readApiKey(source) {
  for (const line of source.split(/\r?\n/)) {
    const match = line.match(/^\s*OPENAI_API_KEY\s*=\s*(.+?)\s*$/);
    if (!match) continue;
    const value = match[1].replace(/^['"]|['"]$/g, "");
    if (value) return value;
  }
  throw new Error("OPENAI_API_KEY is missing from .env");
}

function outputText(response) {
  return (response.output ?? [])
    .flatMap((item) => item.content ?? [])
    .filter((item) => item.type === "output_text")
    .map((item) => item.text)
    .join("\n")
    .trim();
}

const root = new URL("../", import.meta.url);
const apiKey = readApiKey(await readFile(new URL(".env", root), "utf8"));
const memory = await readFamilyMemory(new URL("local-data/memory.json", root));
const memoryContext = formatMemoryForPrompt(memory);
const instructions = `${ROCKY_INSTRUCTIONS}\n\nSAVED FAMILY MEMORY — PRIVATE LOCAL CONTEXT\n${memoryContext}`;
const model = process.env.ROCKY_TEXT_EVAL_MODEL ?? "gpt-5.4-mini";
const lines = [`# Rocky text conversation`, ``, `Started: ${new Date().toLocaleString()}`, `Model: ${model}`, ``];
let previousResponseId;

async function respond(input) {
  const response = await fetch("https://api.openai.com/v1/responses", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${apiKey}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      model,
      instructions,
      input,
      ...(previousResponseId ? { previous_response_id: previousResponseId } : {}),
      max_output_tokens: 400,
    }),
  });
  if (!response.ok) throw new Error(`OpenAI ${response.status}: ${(await response.text()).slice(0, 800)}`);
  const data = await response.json();
  previousResponseId = data.id;
  return outputText(data);
}

async function saveTranscript() {
  const directory = new URL("local-data/text-chats/", root);
  await mkdir(directory, { recursive: true });
  const filename = `${new Date().toISOString().replace(/[:.]/g, "-")}.md`;
  await writeFile(new URL(filename, directory), `${lines.join("\n")}\n`, "utf8");
  return `local-data/text-chats/${filename}`;
}

async function exchange(input) {
  const answer = await respond(input);
  lines.push(`**You**  `, input, ``, `**Rocky**  `, answer, ``);
  console.log(`\nRocky: ${answer}\n`);
}

const oneShot = process.argv.slice(2).filter((argument) => argument !== "--").join(" ").trim();
if (oneShot) {
  await exchange(oneShot);
  console.log(`Saved: ${await saveTranscript()}`);
} else {
  console.log(`Rocky text lab · ${model}`);
  console.log("Commands: /quit, /reset\n");
  await exchange("A new family conversation just started. Give the first greeting.");
  const readline = createInterface({ input: process.stdin, output: process.stdout });
  try {
    while (true) {
      const input = (await readline.question("You: ")).trim();
      if (!input) continue;
      if (input === "/quit") break;
      if (input === "/reset") {
        previousResponseId = undefined;
        console.log("Conversation context reset.\n");
        continue;
      }
      await exchange(input);
    }
  } finally {
    readline.close();
    console.log(`Saved: ${await saveTranscript()}`);
  }
}

