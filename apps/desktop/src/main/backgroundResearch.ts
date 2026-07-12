import { randomUUID } from "node:crypto";
import { mkdir, readdir, readFile, stat, writeFile } from "node:fs/promises";
import path from "node:path";

export const DEFAULT_RESEARCH_TIMEOUT_MS = 60_000;

export interface BackgroundResearchInput {
  question: string;
  context?: string;
}

export interface BackgroundResearchResult {
  id: string;
  question: string;
  answer: string;
  path: string;
  completedAt: string;
}

export interface BackgroundResearchStatus {
  id: string;
  status: "started" | "complete" | "error";
  updatedAt: string;
  question?: string;
  path?: string;
  message?: string;
}

interface ResearchStatusRecord {
  id?: unknown;
  status?: unknown;
  updatedAt?: unknown;
  question?: unknown;
  path?: unknown;
  message?: unknown;
}

function cleanText(value: unknown, fallback = ""): string {
  return typeof value === "string" ? value.trim().slice(0, 2_000) : fallback;
}

export function normalizeResearchInput(value: unknown): BackgroundResearchInput {
  const source = typeof value === "object" && value !== null ? value as Record<string, unknown> : {};
  const question = cleanText(source.question);
  if (!question) throw new Error("Research question is required.");
  return {
    question,
    context: cleanText(source.context),
  };
}

function outputText(response: unknown): string {
  const source = typeof response === "object" && response !== null ? response as { output?: unknown[] } : {};
  return (source.output ?? [])
    .flatMap((item) => {
      const entry = typeof item === "object" && item !== null ? item as { content?: unknown[] } : {};
      return entry.content ?? [];
    })
    .map((content) => {
      const entry = typeof content === "object" && content !== null ? content as { text?: unknown } : {};
      return typeof entry.text === "string" ? entry.text : "";
    })
    .filter(Boolean)
    .join("\n")
    .trim();
}

function shortLine(value: unknown, maxLength: number): string {
  if (typeof value !== "string") return "";
  return value.replace(/\s+/g, " ").trim().slice(0, maxLength);
}

function markdownExcerpt(markdown: string, maxLength: number): string {
  return markdown
    .replace(/^# .+$/gm, "")
    .replace(/^Question:.+$/gm, "")
    .replace(/\[(.*?)\]\((.*?)\)/g, "$1 ($2)")
    .replace(/\s+/g, " ")
    .trim()
    .slice(0, maxLength);
}

async function readStatusRecords(outputDirectory: string): Promise<ResearchStatusRecord[]> {
  const statusDirectory = path.join(outputDirectory, "status");
  const filenames = await readdir(statusDirectory).catch(() => []);
  const records = await Promise.all(
    filenames
      .filter((filename) => filename.endsWith(".json"))
      .map(async (filename) => {
        try {
          return JSON.parse(await readFile(path.join(statusDirectory, filename), "utf8")) as ResearchStatusRecord;
        } catch {
          return null;
        }
      }),
  );
  return records
    .filter((record): record is ResearchStatusRecord => Boolean(record))
    .sort((left, right) => String(right.updatedAt ?? "").localeCompare(String(left.updatedAt ?? "")));
}

function normalizeStatusRecord(record: ResearchStatusRecord): BackgroundResearchStatus | null {
  const id = shortLine(record.id, 80);
  const status = shortLine(record.status, 20);
  const updatedAt = shortLine(record.updatedAt, 40);
  if (!id || !updatedAt || (status !== "started" && status !== "complete" && status !== "error")) return null;
  const question = shortLine(record.question, 500);
  const resultPath = shortLine(record.path, 500);
  const message = shortLine(record.message, 500);
  return {
    id,
    status,
    updatedAt,
    ...(question ? { question } : {}),
    ...(resultPath ? { path: resultPath } : {}),
    ...(message ? { message } : {}),
  };
}

export async function listRecentResearchStatuses(
  outputDirectory: string,
  limit = 10,
): Promise<BackgroundResearchStatus[]> {
  return (await readStatusRecords(outputDirectory))
    .map(normalizeStatusRecord)
    .filter((record): record is BackgroundResearchStatus => Boolean(record))
    .slice(0, Math.max(1, Math.min(30, limit)));
}

async function readRecentResultFiles(outputDirectory: string): Promise<Array<{ path: string; mtimeMs: number; text: string }>> {
  const filenames = await readdir(outputDirectory).catch(() => []);
  const files = await Promise.all(
    filenames
      .filter((filename) => filename.endsWith(".md"))
      .map(async (filename) => {
        const filePath = path.join(outputDirectory, filename);
        try {
          const metadata = await stat(filePath);
          return { path: filePath, mtimeMs: metadata.mtimeMs, text: await readFile(filePath, "utf8") };
        } catch {
          return null;
        }
      }),
  );
  return files
    .filter((file): file is { path: string; mtimeMs: number; text: string } => Boolean(file))
    .sort((left, right) => right.mtimeMs - left.mtimeMs)
    .slice(0, 3);
}

export async function formatRecentResearchForPrompt(outputDirectory: string): Promise<string> {
  const [records, resultFiles] = await Promise.all([
    readStatusRecords(outputDirectory),
    readRecentResultFiles(outputDirectory),
  ]);
  const lines: string[] = [];
  for (const record of records.slice(0, 5)) {
    const status = shortLine(record.status, 20) || "unknown";
    const question = shortLine(record.question, 240) || "unknown question";
    const updatedAt = shortLine(record.updatedAt, 40);
    const message = shortLine(record.message, 240);
    const resultPath = shortLine(record.path, 260);
    lines.push(`- ${status}${updatedAt ? ` at ${updatedAt}` : ""}: ${question}${message ? ` (${message})` : ""}`);
    if (status === "complete" && resultPath) {
      const result = resultFiles.find((file) => file.path === resultPath);
      if (result) lines.push(`  excerpt: ${markdownExcerpt(result.text, 900)}`);
    }
  }
  const knownPaths = new Set(records.map((record) => shortLine(record.path, 260)).filter(Boolean));
  for (const result of resultFiles.filter((file) => !knownPaths.has(file.path)).slice(0, 2)) {
    lines.push(`- complete legacy result: ${path.basename(result.path)}`);
    lines.push(`  excerpt: ${markdownExcerpt(result.text, 900)}`);
  }
  return lines.join("\n");
}

export async function runBackgroundResearch(
  input: BackgroundResearchInput,
  outputDirectory: string,
  apiKey: string,
  id = randomUUID(),
): Promise<BackgroundResearchResult> {
  const model = process.env.ROCKY_RESEARCH_MODEL ?? "gpt-5.5";
  const timeoutMs = Math.max(10_000, Math.min(180_000, Number(process.env.ROCKY_RESEARCH_TIMEOUT_MS) || DEFAULT_RESEARCH_TIMEOUT_MS));
  const maxOutputTokens = Math.max(300, Math.min(4_000, Number(process.env.ROCKY_RESEARCH_MAX_OUTPUT_TOKENS) || 900));
  const reasoningEffort = process.env.ROCKY_RESEARCH_REASONING_EFFORT ?? "low";
  const prompt = [
    "You are a slower background research helper for Rocky, a family voice companion.",
    "Answer with concise, kid-safe facts. Use web search when needed.",
    "Include source links inline when facts may have changed recently.",
    "",
    `Question: ${input.question}`,
    input.context ? `Conversation context: ${input.context}` : "",
  ].filter(Boolean).join("\n");

  await mkdir(outputDirectory, { recursive: true });
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), timeoutMs);
  const response = await fetch("https://api.openai.com/v1/responses", {
    method: "POST",
    signal: controller.signal,
    headers: {
      Authorization: `Bearer ${apiKey}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      model,
      max_output_tokens: maxOutputTokens,
      reasoning: { effort: reasoningEffort },
      tools: [{ type: "web_search" }],
      input: prompt,
    }),
  }).finally(() => clearTimeout(timeout));
  if (!response.ok) throw new Error(`Research failed (${response.status}): ${(await response.text()).slice(0, 800)}`);

  const raw = await response.json() as unknown;
  const answer = outputText(raw) || "Research finished, but no answer text was returned.";
  const completedAt = new Date().toISOString();
  const filePath = path.join(outputDirectory, `${completedAt.replace(/[:.]/g, "-")}-${id.slice(0, 8)}.md`);
  await writeFile(filePath, `# Rocky background research\n\nQuestion: ${input.question}\n\n${answer}\n`, "utf8");
  return { id, question: input.question, answer, path: filePath, completedAt };
}
