import { mkdtemp, mkdir, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";

import { describe, expect, it } from "vitest";

import { DEFAULT_RESEARCH_TIMEOUT_MS, formatRecentResearchForPrompt, normalizeResearchInput } from "./backgroundResearch";

describe("background research", () => {
  it("uses a pause-friendly default timeout", () => {
    expect(DEFAULT_RESEARCH_TIMEOUT_MS).toBe(60_000);
  });

  it("normalizes a research request", () => {
    expect(normalizeResearchInput({ question: "  Which Minecraft version is current?  ", context: "biomes" }))
      .toEqual({ question: "Which Minecraft version is current?", context: "biomes" });
  });

  it("requires a question", () => {
    expect(() => normalizeResearchInput({ question: " " })).toThrow("Research question is required.");
  });

  it("formats durable recent status and legacy results for prompt context", async () => {
    const directory = await mkdtemp(path.join(os.tmpdir(), "rocky-research-"));
    await mkdir(path.join(directory, "status"));
    const resultPath = path.join(directory, "2026-07-12-result.md");
    await writeFile(
      resultPath,
      "# Rocky background research\n\nQuestion: Current mod?\n\nCobblemon uses Fabric or NeoForge now.",
      "utf8",
    );
    await writeFile(
      path.join(directory, "status", "abc.json"),
      JSON.stringify({
        id: "abc",
        status: "complete",
        updatedAt: "2026-07-12T02:14:04.000Z",
        question: "What is current Cobblemon setup?",
        path: resultPath,
      }),
      "utf8",
    );

    const context = await formatRecentResearchForPrompt(directory);

    expect(context).toContain("complete at 2026-07-12T02:14:04.000Z");
    expect(context).toContain("What is current Cobblemon setup?");
    expect(context).toContain("Cobblemon uses Fabric or NeoForge now.");
  });
});
