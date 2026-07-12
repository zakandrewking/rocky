import { mkdtemp, readFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";

import { describe, expect, it } from "vitest";

import { appendContinuity, formatContinuityForPrompt } from "./sessionContinuity";

describe("session continuity", () => {
  it("stores recent non-system transcript turns for the next session", async () => {
    const directory = await mkdtemp(path.join(os.tmpdir(), "rocky-continuity-"));
    const filePath = path.join(directory, "continuity.json");
    await appendContinuity(filePath, { sessionId: "s1", role: "user", text: "We were editing biomes." });
    await appendContinuity(filePath, { sessionId: "s1", role: "rocky", text: "Can hear. Sheet changed." });
    await appendContinuity(filePath, { sessionId: "s1", role: "system", text: "Connection ended." });

    const prompt = await formatContinuityForPrompt(filePath);
    expect(prompt).toContain("Human: We were editing biomes.");
    expect(prompt).toContain("Rocky: Can hear. Sheet changed.");
    expect(prompt).not.toContain("Connection ended");
    expect(JSON.parse(await readFile(filePath, "utf8")).items).toHaveLength(2);
  });

  it("keeps only a bounded rolling window", async () => {
    const directory = await mkdtemp(path.join(os.tmpdir(), "rocky-continuity-window-"));
    const filePath = path.join(directory, "continuity.json");
    for (let index = 0; index < 30; index += 1) {
      await appendContinuity(filePath, { sessionId: "s1", role: "user", text: `turn ${index}` });
    }

    const prompt = await formatContinuityForPrompt(filePath);
    expect(prompt).not.toContain("turn 0");
    expect(prompt).toContain("turn 29");
    expect(JSON.parse(await readFile(filePath, "utf8")).items).toHaveLength(24);
  });
});
