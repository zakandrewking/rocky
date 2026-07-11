import { mkdir, readdir, readFile, writeFile } from "node:fs/promises";
import path from "node:path";

import {
  ROCKY_DEFAULT_REPLY_CASE,
  ROCKY_GREETING_CASE,
  evaluateRockyStyle,
} from "../apps/desktop/src/shared/rockyStyle.ts";
import { isGreetingTurn, parseConversationTurns } from "../apps/desktop/src/shared/transcriptReview.ts";

const root = path.resolve(new URL("../", import.meta.url).pathname);
const sources = [
  { directory: path.join(root, "local-data/transcripts"), firstRockyIsGreeting: true },
  { directory: path.join(root, "local-data/text-chats"), firstRockyIsGreeting: false },
];

async function markdownFiles(directory) {
  try {
    return (await readdir(directory))
      .filter((name) => name.endsWith(".md"))
      .sort()
      .map((name) => path.join(directory, name));
  } catch (error) {
    if (error?.code === "ENOENT") return [];
    throw error;
  }
}

const reviews = [];
for (const source of sources) {
  for (const filename of await markdownFiles(source.directory)) {
    const turns = parseConversationTurns(await readFile(filename, "utf8"));
    turns.forEach((turn, index) => {
      if (turn.role !== "rocky") return;
      const greeting = isGreetingTurn(turns, index, source.firstRockyIsGreeting);
      const styleCase = greeting ? ROCKY_GREETING_CASE : ROCKY_DEFAULT_REPLY_CASE;
      reviews.push({
        filename: path.relative(root, filename),
        kind: greeting ? "greeting" : "reply",
        text: turn.text,
        ...evaluateRockyStyle(styleCase, turn.text),
      });
    });
  }
}

const failures = reviews.filter((review) => review.failures.length > 0);
const lines = [
  "# Rocky transcript review",
  "",
  `Reviewed: ${new Date().toLocaleString()}`,
  `Result: ${reviews.length - failures.length}/${reviews.length} utterances passed`,
  "",
];

for (const review of failures) {
  lines.push(
    `## FAIL · ${review.kind} · ${review.filename}`,
    "",
    review.text,
    "",
    ...review.failures.map((failure) => `- ${failure}`),
    "",
  );
}
if (!failures.length) lines.push("All captured Rocky utterances pass the current contract.", "");

const reportDirectory = path.join(root, "local-data/evals");
await mkdir(reportDirectory, { recursive: true });
const reportPath = path.join(reportDirectory, "latest-transcript-review.md");
await writeFile(reportPath, `${lines.join("\n")}\n`, "utf8");

console.log(`${reviews.length - failures.length}/${reviews.length} captured Rocky utterances passed.`);
for (const review of failures) {
  console.log(`FAIL ${review.filename} (${review.kind})`);
  for (const failure of review.failures) console.log(`  - ${failure}`);
}
console.log(`Report: ${path.relative(root, reportPath)}`);
