import { mkdtemp } from "node:fs/promises";
import os from "node:os";
import path from "node:path";

import { describe, expect, it } from "vitest";

import { formatMemoryForPrompt, readFamilyMemory, rememberFamilyFact } from "./memory";

describe("local family memory", () => {
  it("starts empty when the local file does not exist", async () => {
    const directory = await mkdtemp(path.join(os.tmpdir(), "rocky-memory-"));
    const memory = await readFamilyMemory(path.join(directory, "memory.json"));
    expect(memory.people).toEqual([]);
    expect(formatMemoryForPrompt(memory)).toBe("No saved family memories yet.");
  });

  it("saves, reloads, formats, and deduplicates volunteered facts", async () => {
    const directory = await mkdtemp(path.join(os.tmpdir(), "rocky-memory-"));
    const filePath = path.join(directory, "memory.json");
    const first = await rememberFamilyFact(filePath, { person: "Maya", fact: "Loves volcano experiments" });
    const duplicate = await rememberFamilyFact(filePath, { person: "maya", fact: "loves volcano experiments" });
    const memory = await readFamilyMemory(filePath);

    expect(first.saved).toBe(true);
    expect(duplicate.saved).toBe(false);
    expect(memory.people[0]?.facts).toHaveLength(1);
    expect(formatMemoryForPrompt(memory)).toContain("Maya: Loves volcano experiments");
  });

  it("refuses sensitive facts", async () => {
    const directory = await mkdtemp(path.join(os.tmpdir(), "rocky-memory-"));
    await expect(rememberFamilyFact(path.join(directory, "memory.json"), {
      person: "Maya",
      fact: "School address is 123 Example Street",
    })).rejects.toThrow("does not store sensitive personal information");
  });
});

