import { randomUUID } from "node:crypto";
import { mkdir, writeFile } from "node:fs/promises";
import path from "node:path";

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

export async function runBackgroundResearch(
  input: BackgroundResearchInput,
  outputDirectory: string,
  apiKey: string,
  id = randomUUID(),
): Promise<BackgroundResearchResult> {
  const model = process.env.ROCKY_RESEARCH_MODEL ?? "gpt-5.5";
  const prompt = [
    "You are a slower background research helper for Rocky, a family voice companion.",
    "Answer with concise, kid-safe facts. Use web search when needed.",
    "Include source links inline when facts may have changed recently.",
    "",
    `Question: ${input.question}`,
    input.context ? `Conversation context: ${input.context}` : "",
  ].filter(Boolean).join("\n");

  await mkdir(outputDirectory, { recursive: true });
  const response = await fetch("https://api.openai.com/v1/responses", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${apiKey}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      model,
      reasoning: { effort: "high" },
      tools: [{ type: "web_search" }],
      input: prompt,
    }),
  });
  if (!response.ok) throw new Error(`Research failed (${response.status}): ${(await response.text()).slice(0, 800)}`);

  const raw = await response.json() as unknown;
  const answer = outputText(raw) || "Research finished, but no answer text was returned.";
  const completedAt = new Date().toISOString();
  const filePath = path.join(outputDirectory, `${completedAt.replace(/[:.]/g, "-")}-${id.slice(0, 8)}.md`);
  await writeFile(filePath, `# Rocky background research\n\nQuestion: ${input.question}\n\n${answer}\n`, "utf8");
  return { id, question: input.question, answer, path: filePath, completedAt };
}
