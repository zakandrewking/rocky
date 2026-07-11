import { mkdir, readFile, writeFile } from "node:fs/promises";
import process from "node:process";

import { ROCKY_INSTRUCTIONS } from "../apps/desktop/src/main/prompt.ts";

const NEGATIVE_PATTERNS = [
  /\b(?:i['’]m|i['’]d|i['’]ll|i['’]ve|you['’]re|we['’]re|it['’]s|can['’]t|cannot['’]t|don['’]t|won['’]t|let['’]s)\b/i,
  /—/,
  /\ball ears\b/i,
  /\bhow can i (?:help|assist)\b/i,
  /\bwhat(?:'|’)s on your mind\b/i,
  /\bhappy to help\b/i,
  /\bglad you(?:'|’)re here\b/i,
  /\blet(?:'|’)s dive in\b/i,
  /\bcertainly[!,]/i,
  /\babsolutely[!,]/i,
  /\bi would be happy to\b/i,
  /\bhere is a detailed explanation\b/i,
  /\bsmell\b/i,
  /<[^>]+>/,
  /[*_#]{2,}/,
];

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

function evaluate(testCase, text) {
  const lower = text.toLowerCase();
  const failures = [];
  const words = text.trim().split(/\s+/).filter(Boolean).length;
  if (words > testCase.maxWords) failures.push(`too long: ${words}/${testCase.maxWords} words`);
  for (const pattern of NEGATIVE_PATTERNS) {
    if (pattern.test(text)) failures.push(`negative pattern: ${pattern}`);
  }
  for (const required of testCase.requiredAll ?? []) {
    if (!lower.includes(required.toLowerCase())) failures.push(`missing required phrase: ${required}`);
  }
  if (testCase.requiredAny?.length && !testCase.requiredAny.some((value) => lower.includes(value.toLowerCase()))) {
    failures.push(`missing any of: ${testCase.requiredAny.join(", ")}`);
  }
  for (const forbidden of testCase.forbiddenAny ?? []) {
    if (lower.includes(forbidden.toLowerCase())) failures.push(`forbidden phrase: ${forbidden}`);
  }
  return { failures, words };
}

async function generate(apiKey, model, input) {
  const response = await fetch("https://api.openai.com/v1/responses", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${apiKey}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      model,
      instructions: ROCKY_INSTRUCTIONS,
      input,
      max_output_tokens: 300,
    }),
  });
  if (!response.ok) throw new Error(`OpenAI ${response.status}: ${(await response.text()).slice(0, 800)}`);
  return outputText(await response.json());
}

const apiKey = readApiKey(await readFile(new URL("../.env", import.meta.url), "utf8"));
const cases = JSON.parse(await readFile(new URL("../evals/rocky-style-cases.json", import.meta.url), "utf8"));
const selectedName = process.argv.slice(2).filter((argument) => argument !== "--").join(" ").trim();
const selected = selectedName ? cases.filter((testCase) => testCase.name === selectedName) : cases;
if (!selected.length) throw new Error(`No eval case named: ${selectedName}`);
// Realtime models are not currently exposed to this account through the Responses endpoint.
// Use a fast hosted text model for prompt iteration, then verify winners on the live voice model.
const model = process.env.ROCKY_TEXT_EVAL_MODEL ?? "gpt-5.4-mini";
const runs = Math.max(1, Math.min(10, Number.parseInt(process.env.ROCKY_EVAL_RUNS ?? "1", 10) || 1));
let failed = 0;
const total = selected.length * runs;
const report = [
  `# Rocky text eval`,
  ``,
  `Model: ${model}`,
  `Started: ${new Date().toLocaleString()}`,
  `Repetitions: ${runs}`,
  ``,
];

console.log(`Rocky text eval · ${model} · ${runs} repetition${runs === 1 ? "" : "s"}\n`);
for (let run = 1; run <= runs; run += 1) {
  for (const testCase of selected) {
    const text = await generate(apiKey, model, testCase.input);
    const result = evaluate(testCase, text);
    if (result.failures.length) failed += 1;
    const runLabel = runs > 1 ? ` · run ${run}` : "";
    console.log(`${result.failures.length ? "FAIL" : "PASS"} · ${testCase.name}${runLabel} · ${result.words} words`);
    console.log(text);
    for (const failure of result.failures) console.log(`  - ${failure}`);
    console.log();
    report.push(
      `## ${result.failures.length ? "FAIL" : "PASS"}: ${testCase.name}${runLabel}`,
      ``,
      text,
      ``,
      ...(result.failures.length ? result.failures.map((failure) => `- ${failure}`) : []),
      ``,
    );
  }
}

const evalDirectory = new URL("../local-data/evals/", import.meta.url);
await mkdir(evalDirectory, { recursive: true });
const reportName = `${new Date().toISOString().replace(/[:.]/g, "-")}.md`;
await writeFile(new URL(reportName, evalDirectory), report.join("\n"), "utf8");
console.log(`Saved ignored eval report: local-data/evals/${reportName}\n`);

if (failed) {
  console.error(`${failed}/${total} cases failed.`);
  process.exitCode = 1;
} else {
  console.log(`${total}/${total} cases passed.`);
}
